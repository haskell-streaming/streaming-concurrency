# Revision history for streaming-concurrency

## 0.2.0.1  -- 2017-07-05

* Fix lower bound of `lifted-async` (`replicateConcurrently_` was
  added in 0.9.3).

## 0.2.0.0  -- 2017-07-05

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

## 0.1.0.0  -- 2017-07-04

* First version.
