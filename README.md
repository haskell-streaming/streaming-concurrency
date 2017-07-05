streaming-concurrency
==============

[![Hackage](https://img.shields.io/hackage/v/streaming-concurrency.svg)](https://hackage.haskell.org/package/streaming-concurrency) [![Build Status](https://travis-ci.org/ivan-m/streaming-concurrency.svg)](https://travis-ci.org/ivan-m/streaming-concurrency)

> Concurrency for the [streaming] ecosystem

Two

The primary purpose for this library is to be able to merge multiple
`Stream`s together.  However, it is possible to build higher
abstractions on top of this to be able to also feed multiple streams.

[streaming]: http://hackage.haskell.org/package/streaming

Thanks and recognition
----------------------

The code here is heavily based upon -- and borrows the underlying
`Buffer` code from -- Gabriel Gonzalez's [pipes-concurrency].  It
differs from it primarily in being more bracket-oriented rather than
providing a `spawn` primitive, thus not requiring explicit garbage
collection.

[pipes-concurrency]: http://hackage.haskell.org/package/pipes-concurrency
