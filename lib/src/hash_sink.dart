// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library crypto.hash_base;

import 'dart:typed_data';

import 'package:typed_data/typed_data.dart';

import 'digest.dart';
import 'utils.dart';

/// A base class for [Sink] implementations for hash algorithms.
///
/// Subclasses should override [updateHash] and [digest].
abstract class HashSink implements Sink<List<int>> {
  /// The inner sink that this should forward to.
  final Sink<Digest> _sink;

  /// Whether the hash function operates on big-endian words.
  final Endianness _endian;

  /// The words in the current chunk.
  ///
  /// This is an instance variable to avoid re-allocating, but its data isn't
  /// used across invocations of [_iterate].
  final Uint32List _currentChunk;

  /// The length of the input data so far, in bytes.
  int _lengthInBytes = 0;

  /// Data that has yet to be processed by the hash function.
  final _pendingData = new Uint8Buffer();

  /// Whether [close] has been called.
  bool _isClosed = false;

  /// The words in the current digest.
  ///
  /// This should be updated each time [updateHash] is called.
  Uint32List get digest;

  /// Creates a new hash.
  ///
  /// [chunkSizeInWords] represents the size of the input chunks processed by
  /// the algorithm, in terms of 32-bit words.
  HashSink(this._sink, int chunkSizeInWords,
          {Endianness endian: Endianness.BIG_ENDIAN})
      : _endian = endian,
        _currentChunk = new Uint32List(chunkSizeInWords);

  /// Runs a single iteration of the hash computation, updating [digest] with
  /// the result.
  ///
  /// [m] is the current chunk, whose size is given by the `chunkSizeInWords`
  /// parameter passed to the constructor.
  void updateHash(Uint32List chunk);

  void add(List<int> data) {
    if (_isClosed) throw new StateError('Hash.add() called after close().');
    _lengthInBytes += data.length;
    _pendingData.addAll(data);
    _iterate();
  }

  void close() {
    if (_isClosed) return;
    _isClosed = true;

    _finalizeData();
    _iterate();
    assert(_pendingData.isEmpty);
    _sink.add(new Digest(_byteDigest()));
  }

  Uint8List _byteDigest() {
    if (_endian == Endianness.HOST_ENDIAN) return digest.buffer.asUint8List();

    var byteDigest = new Uint8List(digest.lengthInBytes);
    var byteData = byteDigest.buffer.asByteData();
    for (var i = 0; i < digest.length; i++) {
      byteData.setUint32(i * bytesPerWord, digest[i]);
    }
    return byteDigest;
  }

  /// Iterates through [_pendingData], updating the hash computation for each
  /// chunk.
  void _iterate() {
    var pendingDataBytes = _pendingData.buffer.asByteData();
    var pendingDataChunks = _pendingData.length ~/ _currentChunk.lengthInBytes;
    for (var i = 0; i < pendingDataChunks; i++) {
      // Copy words from the pending data buffer into the current chunk buffer.
      for (var j = 0; j < _currentChunk.length; j++) {
        _currentChunk[j] = pendingDataBytes.getUint32(
            i * _currentChunk.lengthInBytes + j * bytesPerWord, _endian);
      }

      // Run the hash function on the current chunk.
      updateHash(_currentChunk);
    }

    // Remove all pending data up to the last clean chunk break.
    _pendingData.removeRange(
        0, pendingDataChunks * _currentChunk.lengthInBytes);
  }

  /// Finalizes [_pendingData].
  ///
  /// This adds a 1 bit to the end of the message, and expands it with 0 bits to
  /// pad it out.
  void _finalizeData() {
    // Pad out the data with 0x80, eight 0s, and as many more 0s as we need to
    // land cleanly on a chunk boundary.
    _pendingData.add(0x80);
    var contentsLength = _lengthInBytes + 9;
    var finalizedLength = _roundUp(contentsLength, _currentChunk.lengthInBytes);
    for (var i = 0; i < finalizedLength - contentsLength; i++) {
      _pendingData.add(0);
    }

    var lengthInBits = _lengthInBytes * bitsPerByte;
    if (lengthInBits > maxUint64) {
      throw new UnsupportedError(
          "Hashing is unsupported for messages with more than 2^64 bits.");
    }

    // Add the full length of the input data as a 64-bit value at the end of the
    // hash.
    var offset = _pendingData.length;
    _pendingData.addAll(new Uint8List(8));
    _pendingData.buffer.asByteData().setUint64(offset, lengthInBits, _endian);
  }

  /// Rounds [val] up to the next multiple of [n], as long as [n] is a power of
  /// two.
  int _roundUp(int val, int n) => (val + n - 1) & -n;
}
