---
name: frb-patterns
description: Flutter Rust Bridge patterns and best practices for this project. Use when writing Rust API code, adding new bindings, implementing DartFn callbacks, or troubleshooting FRB issues.
---

# FFI Patterns for openmls

Patterns and templates for writing correct Dart FFI code in this project.

## Memory Allocation

### Allocate Bytes

```dart
final ptr = OpenmlsUtils.allocateBytes(length);
try {
  // Use ptr...
} finally {
  OpenmlsUtils.freePointer(ptr);  // or secureFreePointer for secrets
}
```

### Convert Uint8List to Pointer

```dart
final ptr = OpenmlsUtils.uint8ListToPointer(data);
try {
  // Use ptr...
} finally {
  OpenmlsUtils.freePointer(ptr);
}
```

### Convert Pointer to Uint8List

```dart
final result = OpenmlsUtils.pointerToUint8List(ptr, length);
// Result is a copy - safe to free ptr after this
```

## String Handling

```dart
final namePtr = algorithmName.toNativeUtf8();
try {
  final result = bindings.some_native_function(namePtr.cast());
  // ...
} finally {
  OpenmlsUtils.freePointer(namePtr);
}
```

## Wrapper Class Pattern

```dart
// Finalizer for automatic cleanup
final Finalizer<Pointer<bindings.NativeStruct>> _structFinalizer = Finalizer(
  (ptr) => bindings.native_struct_free(ptr),
);

class WrapperClass {
  late final Pointer<bindings.NativeStruct> _ptr;
  bool _disposed = false;

  WrapperClass._(this._ptr) {
    // Attach finalizer for GC cleanup
    _structFinalizer.attach(this, _ptr, detach: this);
  }

  void _checkDisposed() {
    if (_disposed) {
      throw StateError('Instance has been disposed');
    }
  }

  // Factory constructor
  static WrapperClass create(String name) {
    OpenmlsBase.init();  // Auto-initialize library

    final namePtr = name.toNativeUtf8();
    try {
      final ptr = bindings.native_struct_new(namePtr.cast());
      if (ptr == nullptr) {
        throw OpenmlsException('Failed to create instance');
      }
      return WrapperClass._(ptr);
    } finally {
      OpenmlsUtils.freePointer(namePtr);
    }
  }

  // Dispose pattern
  void dispose() {
    if (!_disposed) {
      bindings.native_struct_free(_ptr);  // 1. Free native memory
      _structFinalizer.detach(this);       // 2. Detach finalizer
      _disposed = true;                     // 3. Set flag
    }
  }
}
```

## Data Class with Secrets

```dart
final Finalizer<Uint8List> _secretFinalizer = Finalizer((data) {
  OpenmlsUtils.zeroMemory(data);
});

class KeyPair {
  final Uint8List publicKey;
  final Uint8List secretKey;

  KeyPair({required this.publicKey, required this.secretKey}) {
    // Auto-zero secret on GC (defense-in-depth)
    _secretFinalizer.attach(this, secretKey, detach: this);
  }

  /// Zero secrets immediately (recommended)
  void clearSecrets() {
    OpenmlsUtils.zeroMemory(secretKey);
  }

  /// Safe: only exposes public key
  String get publicKeyBase64 => base64Encode(publicKey);

  /// **Security Warning:** Exports SECRET KEY in plaintext!
  Map<String, String> toStrings() {
    return {
      'publicKey': base64Encode(publicKey),
      'secretKey': base64Encode(secretKey),
    };
  }
}
```

## Calling Native Functions

### From Struct Field

```dart
// 1. Validate function pointer
if (_ptr.ref.someFunction == nullptr) {
  throw OpenmlsException('Function pointer is null');
}

// 2. Convert to Dart function
final fn = _ptr.ref.someFunction.asFunction<
  int Function(Pointer<Uint8> input, Pointer<Uint8> output)
>();

// 3. Allocate output buffers
final input = OpenmlsUtils.uint8ListToPointer(inputData);
final output = OpenmlsUtils.allocateBytes(outputLength);

try {
  // 4. Call function
  final result = fn(input, output);

  if (result != 0) {
    throw OpenmlsException('Operation failed', result);
  }

  // 5. Copy results to Dart
  return OpenmlsUtils.pointerToUint8List(output, outputLength);
} finally {
  // 6. Free native memory (secure for secrets!)
  OpenmlsUtils.freePointer(input);
  OpenmlsUtils.secureFreePointer(output, outputLength);
}
```

### Direct Library Call

```dart
final count = bindings.some_count_function();  // Simple - no cleanup needed

final namePtr = bindings.get_name(i);
if (namePtr != nullptr) {
  final name = namePtr.cast<Utf8>().toDartString();
  // Don't free namePtr - it's a static string from library
}
```

## Error Handling

```dart
try {
  final result = nativeFunction(args);
  if (result != 0) {
    throw OpenmlsException('Operation failed', result);
  }
} on OpenmlsException {
  rethrow;  // Preserve our exceptions
} catch (e) {
  throw OpenmlsException('Unexpected error: $e');
}
```

## Utilities Reference

| Method | Use For |
|--------|---------|
| `OpenmlsUtils.allocateBytes(n)` | Allocate n bytes |
| `OpenmlsUtils.freePointer(ptr)` | Free non-sensitive memory |
| `OpenmlsUtils.secureFreePointer(ptr, len)` | Free sensitive memory (zeros first) |
| `OpenmlsUtils.uint8ListToPointer(list)` | Copy Dart list to native |
| `OpenmlsUtils.pointerToUint8List(ptr, len)` | Copy native to Dart list |
| `OpenmlsUtils.zeroMemory(list)` | Zero a Dart Uint8List |
| `OpenmlsUtils.constantTimeEquals(a, b)` | Compare secrets safely |
