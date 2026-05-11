# Cauchy Reed-Solomon in Zig
This is an optimized implementation of Cauchy Reed-Solomon in Zig for use in
fault-tolerance in storage systems and forward error correction (FEC) schemes
such as those used in QUIC.

It is based on [this implementation][ronomon] originally written by Joran Dirk
Greef from Tigerbeetle, but boasts additional improvements over that one:
- Gauss-Jordan matrix inversion is done in-place without allocating scratch
  space and thus significantly reducing memory footprint of decode passes,
  also leveraging certain properties of Galois Fields for additional
  optimizations and doing less work;
- Optimal parameter search has a parallel implementation that is a part of the
  projects harness. Additionally, we also search for the Galois Field primitive
  polynomial 25 when W=4, and have found better parameters for GF(16) on
  multiple cases;
- Parameter search is done automatically through comptime when outside the
  range of our precomputed table, allowing us to cover a wider parameter set
  without sacrificing ergonomics;
- We still match or beat the reference implementation in all cases;


## TODO
- Smart scheduling from [Plank's FAST'08 paper][plank-cs-07-602];
- Better benchmarking against reference implementation and jerasure;
- Make benchmarking more workload oriented, and also more sensitive so we
  can measure low-latency network and transport use cases such as QUIC;
- Improve the fuzzing harness, fuzz against both our reference and jerasure;
- Local Reconstruction Code variants (Azure's narrow + Google's wide LRCs);
- Continuous monitoring for performance and library size;
- Actual documentation and usage guides;


## References
- [Optimizing Cauchy Reed-Solomon Codes for Fault-Tolerant Storage Applications][plank-cs-05-569]
- [Jerasure: A Library Facilitating Erasure Coding for Storage Applications][plank-cs-08-627]
- [A New Minimum Density RAID-6 Code with a Word Size of Eight][plank-nca-2008]


[ronomon]: https://github.com/ronomon/reed-solomon
[plank-cs-05-569]: https://web.eecs.utk.edu/~jplank/plank/papers/CS-05-569.pdf
[plank-cs-07-602]: https://web.eecs.utk.edu/~jplank/plank/papers/CS-07-602.pdf
[plank-cs-08-627]: https://web.eecs.utk.edu/~jplank/plank/papers/CS-08-627.pdf
[plank-nca-2008]: https://web.eecs.utk.edu/~jplank/plank/papers/NCA-2008.pdf

