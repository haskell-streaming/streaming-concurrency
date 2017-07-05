streaming-concurrency
==============

[![Hackage](https://img.shields.io/hackage/v/streaming-concurrency.svg)](https://hackage.haskell.org/package/streaming-concurrency) [![Build Status](https://travis-ci.org/ivan-m/streaming-concurrency.svg)](https://travis-ci.org/ivan-m/streaming-concurrency)

> Concurrency for the [streaming] ecosystem

[streaming]: http://hackage.haskell.org/package/streaming

There are two primary higher-level use-cases for this library:

1. Merge multiple `Stream`s together.

2. A conceptual `Stream`-based equivalent to [`parMap`] (albeit
   utilising concurrency rather than true parallelism).

    [`parMap`]: http://hackage.haskell.org/package/parallel/docs/Control-Parallel-Strategies.html#v:parMap

However, low-level functions are also exposed so you can construct
your own methods of concurrently using `Stream`s (and there are also
non-`Stream`-specific functions if you wish to use it with other data
types).

Conceptually, the approach taken is to consider a typical
correspondence system with an in-basket/tray for receiving messages
for others, and an out-basket/tray to be later dealt with.  Inputs are
thus provided into the `InBasket` and removed once available from the
`OutBasket`.

Thanks and recognition
----------------------

The code here is heavily based upon -- and borrows the underlying
`Buffer` code from -- Gabriel Gonzalez's [pipes-concurrency].  It
differs from it primarily in being more bracket-oriented rather than
providing a `spawn` primitive, thus not requiring explicit garbage
collection.

[pipes-concurrency]: http://hackage.haskell.org/package/pipes-concurrency

Another main difference is that the naming of the `input` and `output`
types has been switched around: [pipes-concurrency] seems to consider
them from the point of view of the supplying/consuming `Pipe`s,
whereas here they are considered from the point of view of the
`Buffer` itself.
