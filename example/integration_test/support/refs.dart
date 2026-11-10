import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'party.dart';

/// The reference to [keyPackage], as the engine's storage keys it:
/// `MakeKeyPackageRef` (RFC 9420 §5.2), on a SHA-256 suite.
Uint8List keyPackageRef(List<int> keyPackage) =>
    _ref('MLS 1.0 KeyPackage Reference', keyPackage);

/// The reference to the proposal [message] carries: `MakeProposalRef` over
/// its AuthenticatedContent (RFC 9420 §5.2), on a SHA-256 suite.
///
/// The engine returns no reference with a proposal, so whoever needs one makes
/// it from the message, and that takes a message in the clear: a
/// PublicMessage, from a member, of a group that sends its handshake messages
/// as plaintext.
Uint8List proposalRef(List<int> message) {
  // An MLSMessage is its version, 2 bytes, then the PublicMessage. Of that,
  // the wire format, the FramedContent and the FramedContentAuthData are the
  // AuthenticatedContent (RFC 9420 §6.1); what follows, from a member, is the
  // membership tag: a MAC, one length byte and 32 bytes of HMAC-SHA256.
  const version = 2;
  const membershipTag = 1 + 32;
  return _ref(
    'MLS 1.0 Proposal Reference',
    message.sublist(version, message.length - membershipTag),
  );
}

/// `RefHash(label, value)` (RFC 9420 §5.2), serialized as the engine reads a
/// reference: as a variable-length vector.
Uint8List _ref(String label, List<int> value) => Uint8List.fromList(
  _vector(
    sha256.convert([..._vector(bytesOf(label)), ..._vector(value)]).bytes,
  ),
);

/// [value] as an MLS variable-length vector: its length as a variable-size
/// integer (RFC 9420 §2.1.2), then the bytes.
List<int> _vector(List<int> value) {
  final n = value.length;
  final length = n < 1 << 6
      ? [n]
      : n < 1 << 14
      ? [0x40 | n >> 8, n & 0xff]
      : [0x80 | n >> 24, n >> 16 & 0xff, n >> 8 & 0xff, n & 0xff];
  return [...length, ...value];
}
