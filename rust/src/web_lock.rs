//! Cross-tab single-writer lock for the Web build.
//!
//! The native build takes a sidecar lock file next to the database and refuses
//! a second opener outright (`encrypted_db::acquire_single_writer_lock`). The
//! Web build had nothing equivalent: every tab of an origin gets its own WASM
//! instance, its own [`MlsEngine`](crate::api::engine::MlsEngine) and therefore
//! its own `op_lock`, while they all address ONE IndexedDB database. Two tabs
//! could load the same snapshot, operate on it, and write back in turn — the
//! second write-back dropping a merged commit, an advanced ratchet or a stored
//! proposal from the first, which desynchronizes the group.
//!
//! The Web Locks API is the cross-context primitive for exactly this. Unlike
//! the native lock it is taken per OPERATION rather than for the engine's
//! lifetime: browser tabs are opened and closed by users, not by the
//! application, so refusing the second tab outright would break an ordinary
//! thing to do. Serializing the operations instead keeps every tab working and
//! still makes the load → operate → save span atomic across them.
//!
//! ⚠ **The lock is held by a PENDING PROMISE, not by a handle.** `request()`
//! holds the lock for exactly as long as the promise its callback returns stays
//! unsettled, so a guard that outlives one async call — which is what this
//! span needs — has to keep that promise pending and resolve it on `Drop`.
//! That is what `held`/`release` below are; there is no "unlock" call to make.
//!
//! ⚠ **Web Locks need a secure context.** `navigator.locks` is undefined on a
//! plain-`http` origin that is not `localhost`, and in that case this module
//! degrades to no cross-tab lock at all rather than failing the operation —
//! which is exactly where the Web build stood before it existed. The engine is
//! unchanged on every other axis, so this is a missing guarantee, never a
//! regression.

use js_sys::{Array, Function, Object, Promise, Reflect};
use wasm_bindgen::prelude::*;
use wasm_bindgen_futures::JsFuture;

/// How long an operation waits for another context to finish before giving up.
///
/// Mirrors the native side's five-second `busy_timeout`: an operation is
/// milliseconds of work, so anything near this bound means another context is
/// wedged rather than busy. Waiting forever would turn that into a hang with
/// nothing to report; this way the caller gets an error it can show.
pub(crate) const WEB_LOCK_TIMEOUT_MS: u32 = 5_000;

/// How long `EncryptedDb::open` waits for another context's migrations.
///
/// Longer than an operation's wait because the work is: a schema migration may
/// rewrite every stored value, and a second tab opening while the first is
/// mid-migration should sit through it rather than report a busy database. It
/// is still bounded — a tab wedged inside a migration must not hang every
/// other tab's startup indefinitely.
pub(crate) const WEB_MIGRATION_TIMEOUT_MS: u32 = 30_000;

/// Holds one exclusive Web Lock until dropped.
///
/// `release` is the resolver of the promise the lock callback returned. Calling
/// it settles that promise, which is what makes the browser hand the lock to
/// whoever is queued next. `None` means this guard holds nothing — see
/// [`unheld`](Self::unheld).
pub(crate) struct WebLockGuard {
    release: Option<Function>,
}

impl WebLockGuard {
    /// A guard that holds no lock, for contexts where the API is absent.
    ///
    /// Returned instead of an error on purpose: the alternative is failing
    /// every MLS operation on an insecure origin, where the Web build worked
    /// before this module existed.
    fn unheld() -> Self {
        Self { release: None }
    }

    /// Whether this guard actually holds a Web Lock.
    #[cfg(test)]
    pub(crate) fn is_held(&self) -> bool {
        self.release.is_some()
    }
}

impl Drop for WebLockGuard {
    fn drop(&mut self) {
        if let Some(release) = self.release.take() {
            // Resolves the promise the callback returned; the browser releases
            // the lock when it settles. A failure here cannot be reported from
            // `Drop` and cannot be retried — but it also cannot happen: this is
            // a resolver function from a promise this module created.
            let _ = release.call0(&JsValue::NULL);
        }
    }
}

/// Take the exclusive Web Lock called `name`, waiting at most `timeout_ms`.
pub(crate) async fn acquire(name: &str, timeout_ms: u32) -> Result<WebLockGuard, String> {
    acquire_with(lock_manager(), name, timeout_ms).await
}

/// [`acquire`] against an explicit `LockManager`, so the absent-API path can be
/// exercised by a test instead of argued about.
async fn acquire_with(
    manager: JsValue,
    name: &str,
    timeout_ms: u32,
) -> Result<WebLockGuard, String> {
    if manager.is_undefined() || manager.is_null() {
        return Ok(WebLockGuard::unheld());
    }

    let request: Function = Reflect::get(&manager, &JsValue::from_str("request"))
        .ok()
        .and_then(|value| value.dyn_into::<Function>().ok())
        .ok_or_else(|| "navigator.locks.request is not callable".to_string())?;

    // The promise that keeps the lock. It stays pending until `release` is
    // called from `Drop`.
    let mut release = None;
    let held = Promise::new(&mut |resolve, _reject| release = Some(resolve));
    let release =
        release.ok_or_else(|| "Promise executor did not run synchronously".to_string())?;

    // Resolved the moment the callback runs, which is the moment the lock is
    // ours. The request promise itself cannot say so: it settles only after the
    // lock is RELEASED again.
    let mut grant = None;
    let granted = Promise::new(&mut |resolve, _reject| grant = Some(resolve));
    let grant = grant.ok_or_else(|| "Promise executor did not run synchronously".to_string())?;

    // ⚠ `once_into_js` hands the closure to JS, which frees it after the call.
    // On the timeout path the callback is never called and that allocation is
    // not reclaimed — one small closure per timed-out operation, which is the
    // price of not keeping a `Closure` alive in the guard for a call that may
    // never come.
    let callback = Closure::once_into_js(move |_lock: JsValue| -> JsValue {
        let _ = grant.call0(&JsValue::NULL);
        held.into()
    });

    let options = Object::new();
    set(&options, "mode", &JsValue::from_str("exclusive"))?;
    if let Some(signal) = abort_after(timeout_ms) {
        set(&options, "signal", &signal)?;
    }

    let pending: Promise = request
        .call3(&manager, &JsValue::from_str(name), &options, &callback)
        .map_err(|e| format!("navigator.locks.request failed: {e:?}"))?
        .dyn_into()
        .map_err(|_| "navigator.locks.request did not return a promise".to_string())?;

    // Whichever comes first: the grant, or the request rejecting because the
    // signal aborted while queued. `pending` cannot resolve before the grant —
    // it settles with the callback's promise, which this guard holds open.
    let race = Promise::race(&Array::of2(&granted, &pending));
    JsFuture::from(race).await.map_err(|e| lock_error(name, &e))?;

    Ok(WebLockGuard { release: Some(release) })
}

/// `navigator.locks`, or `undefined` where the API is not exposed.
///
/// Read off the global rather than through `web_sys::window()`: the same code
/// has to work in a worker, which has no `Window`. `LockManager` is behind
/// `--cfg web_sys_unstable_apis` in web-sys, which would put an unstable flag
/// in every build of this crate; reflection costs one property read per
/// operation and no build configuration at all.
fn lock_manager() -> JsValue {
    let global = js_sys::global();
    let navigator = match Reflect::get(&global, &JsValue::from_str("navigator")) {
        Ok(navigator) => navigator,
        Err(_) => return JsValue::UNDEFINED,
    };
    if navigator.is_undefined() || navigator.is_null() {
        return JsValue::UNDEFINED;
    }
    Reflect::get(&navigator, &JsValue::from_str("locks")).unwrap_or(JsValue::UNDEFINED)
}

/// An `AbortSignal` that fires after `ms`, or `None` where the constructor is
/// missing — in which case the request waits indefinitely, which is what the
/// API does without a signal.
fn abort_after(ms: u32) -> Option<JsValue> {
    let global = js_sys::global();
    let ctor = Reflect::get(&global, &JsValue::from_str("AbortSignal")).ok()?;
    if ctor.is_undefined() || ctor.is_null() {
        return None;
    }
    let timeout: Function = Reflect::get(&ctor, &JsValue::from_str("timeout"))
        .ok()?
        .dyn_into()
        .ok()?;
    timeout.call1(&ctor, &JsValue::from_f64(f64::from(ms))).ok()
}

fn set(target: &Object, key: &str, value: &JsValue) -> Result<(), String> {
    Reflect::set(target, &JsValue::from_str(key), value)
        .map(|_| ())
        .map_err(|e| format!("Failed to build the lock options: {e:?}"))
}

/// Turn a rejected request into a message that says which case it was.
///
/// The timeout is the one a caller can act on — another context is holding the
/// database — so it reads like the native "already open" error rather than
/// like a JavaScript failure.
fn lock_error(name: &str, err: &JsValue) -> String {
    let kind = Reflect::get(err, &JsValue::from_str("name"))
        .ok()
        .and_then(|value| value.as_string())
        .unwrap_or_default();
    if kind == "TimeoutError" || kind == "AbortError" {
        format!(
            "Database is busy: another browser tab or worker is running an MLS \
             operation on \"{name}\". It did not finish within \
             {WEB_LOCK_TIMEOUT_MS} ms."
        )
    } else {
        format!("Failed to take the Web Lock \"{name}\": {err:?}")
    }
}

#[cfg(test)]
mod web_tests {
    use super::*;
    use wasm_bindgen_test::{wasm_bindgen_test, wasm_bindgen_test_configure};

    wasm_bindgen_test_configure!(run_in_browser);

    /// A name no other test — or run — can collide with.
    fn unique_name(tag: &str) -> String {
        format!("openmls_frb_test:{tag}:{}", js_sys::Date::now())
    }

    /// The whole contract in one execution: a second taker of the same name
    /// cannot get in while the first holds it, gives up with a message that
    /// names the cause, and gets in once the guard is dropped.
    ///
    /// Two requests from ONE page prove it as well as two tabs would: Web Locks
    /// are per origin, and the queue that serializes tabs is the queue that
    /// serializes these.
    #[wasm_bindgen_test]
    async fn the_lock_is_exclusive_and_released_on_drop() {
        let name = unique_name("exclusive");

        let first = acquire(&name, WEB_LOCK_TIMEOUT_MS).await.expect("first taker gets the lock");
        assert!(first.is_held(), "this browser must expose navigator.locks");

        // Short on purpose: this one is expected to lose, and the test should
        // not sit out the production timeout to find out.
        let blocked = acquire(&name, 150).await;
        let message = blocked.err().expect("the lock must not be handed out twice");
        assert!(
            message.contains("Database is busy"),
            "a contended lock must say so, got: {message}"
        );

        drop(first);

        let second = acquire(&name, WEB_LOCK_TIMEOUT_MS)
            .await
            .expect("dropping the guard must release the lock");
        assert!(second.is_held());
    }

    /// Different databases must not queue behind each other.
    #[wasm_bindgen_test]
    async fn different_names_do_not_contend() {
        let a = acquire(&unique_name("a"), WEB_LOCK_TIMEOUT_MS).await.expect("first name");
        let b = acquire(&unique_name("b"), 150).await.expect("second, unrelated name");
        assert!(a.is_held() && b.is_held());
    }

    /// Where the API is absent the operation proceeds unlocked instead of
    /// failing. Exercised through `acquire_with` because the property being
    /// tested is "no LockManager", which a browser that has one cannot show.
    #[wasm_bindgen_test]
    async fn an_absent_lock_manager_degrades_instead_of_failing() {
        let guard = acquire_with(JsValue::UNDEFINED, "openmls_frb_test:absent", 150)
            .await
            .expect("an absent API must not fail the operation");
        assert!(!guard.is_held(), "nothing is held when there is no LockManager");
    }
}
