source("incl/start.R")

message("*** Demos ...")

message("*** Fibonacci demo of the 'future' package ...")
demo("fibonacci", package = "future", ask = FALSE)
message("*** Fibonacci demo of the 'future' package ... DONE")


message("*** Mandelbrot demo of the 'future' package ...")
if (getRversion() >= "3.2.0" && !isWin32) {
  options(future.demo.mandelbrot.nrow = 2L)
  options(future.demo.mandelbrot.resolution = 50L)
  options(future.demo.mandelbrot.delay = FALSE)
  
  for (cores in 1:availCores) {
    message(sprintf("Testing with %d cores ...", cores))
    options(mc.cores = cores)
  
    for (strategy in supportedStrategies(cores)) {
      message(sprintf("- plan('%s') ...", strategy))
      plan(strategy)
      demo("mandelbrot", package = "future", ask = FALSE)
      message(sprintf("- plan('%s') ... DONE", strategy))
    }
  
    message(sprintf("Testing with %d cores ... DONE", cores))
  } ## for (cores ...)
} else {
  message(" - This demo requires R (>= 3.2.0). Skipping test. (Skipping also on Win32 i386 for speed)")
}
message("*** Mandelbrot demo of the 'future' package ... DONE")

message("*** Demos ... DONE")

source("incl/end.R")
