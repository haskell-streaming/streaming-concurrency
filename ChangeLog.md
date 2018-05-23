# Revision history for streaming-concurrency

## 0.3.1.2 -- 2018-05-23

* Bump lifted-async dependency.

## 0.3.1.1 -- 2018-03-23

* Bump exceptions dependency.

## 0.3.1.0 -- 2018-03-14

* Allow `streaming-0.2.*`

* Improved performance for `withStreamMap` and `withStreamMapM`.

    - Previously used additional `Stream`s within the concurrent
      buffers which isn't actually needed.

    - A benchmark is available to compare various implementations.

* Primitives to help defining custom stream-mapping functions are now
  exported.

## 0.3.0.1 -- 2017-07-07

* Allow `streaming-with-0.2.*`

## 0.3.0.0 -- 2017-07-05

* Removed support for streaming `ByteString`s.

    The ByteString-related functions which were previously implemented
    are broken conceptually and should not be used.

    A ByteString consists of a stream of bytes; the meaning of each byte
    is dependent upon its position in the overall stream.

    In terms of implementation, these bytes are accumulated into
    _chunks_, each of which may very well be of a different size.

    As such, if such a chunk is fed into a buffer with multiple readers,
    then there is no guarantee which reader will actually receive it or if
    it makes sense about what it is in isolation (e.g. it could be split
    mid-word, or possibly even in the middle of a Unicode character).

    If, however, multiple ByteStrings are fed into a buffer with a single
    reader, the order it has when coming out is similarly undeterministic:
    it isn't possible to coherently ensure the sanity of the resulting
    ByteString.

    As such, unless you really want to consider it as a stream of
    raw 8-bit numbers, trying to do any concurrency with a ByteString
    will only lead to trouble.  If you do need such functionality, you
    can implement it yourself using buffers containing `Word8` values
    (in which case you can use `Data.ByteString.Streaming.unpack`).

* Fix lower bound of `lifted-async` (`replicateConcurrently_` was
  added in 0.9.3).

## 0.2.0.0 -- 2017-07-05

* Rename functions to match the `with...` naming scheme:

    - `merge{Streams,ByteStrings}` to `withMerged{Streams,ByteStrings}`
    - `read{Stream,ByteString}Basket` to `with{Stream,ByteString}Basket`

* Add the ability to use buffers to concurrently transform the stream;
  following functions added:

    - `withBufferedTransform`
    - `withStreamMap`
    - `withStreamMapM`
    - `withStreamTransform`

    (Note: it is not sound in the general case to transform a
    streaming `ByteString`; as such, functions for this are not
    implemented though it is possible to do yourself.)

## 0.1.0.0 -- 2017-07-04

* First version.
