#' An multicore future is a future whose value will be resolved asynchronously in a parallel process
#'
#' @inheritParams MultiprocessFuture-class
#' @inheritParams Future-class
#'
#' @return An object of class `MulticoreFuture`.
#'
#' @seealso
#' To evaluate an expression using "multicore future", see function
#' [multicore()].
#'
#' @export
#' @name MulticoreFuture-class
#' @keywords internal
MulticoreFuture <- function(expr = NULL, substitute = TRUE, envir = parent.frame(), globals = TRUE, lazy = FALSE, ...) {
  if (substitute) expr <- substitute(expr)

  ## WORKAROUND: Skip scanning of globals if already done /HB 2021-01-18
  if (!isTRUE(attr(globals, "already-done"))) {
    ## Global objects
    assignToTarget <- (is.list(globals) || inherits(globals, "Globals"))
    gp <- getGlobalsAndPackages(expr, envir = envir, tweak = tweakExpression, globals = globals)
    
    ## Assign?
    if (length(gp) > 0L) {
      if (lazy || assignToTarget || !identical(expr, gp$expr)) {
        expr <- gp$expr
        target <- new.env(parent = envir)
        globalsT <- gp$globals
        for (name in names(globalsT)) {
          target[[name]] <- globalsT[[name]]
        }
        globalsT <- NULL
        envir <- target
      }
    }
    gp <- NULL
  } else {
    target <- new.env(parent = envir)
    for (name in names(globals)) {
      target[[name]] <- globals[[name]]
    }
    envir <- target
  }

  future <- MultiprocessFuture(expr = expr, substitute = FALSE, envir = envir, lazy = lazy, ...)

  future <- as_MulticoreFuture(future, ...)

  future
}


as_MulticoreFuture <- function(future, ...) {
  future$job <- NULL
  
  future <- structure(future, class = c("MulticoreFuture", class(future)))
  
  future
}


#' @export
run.MulticoreFuture <- function(future, ...) {
  debug <- getOption("future.debug", FALSE)
  
  if (future$state != "created") {
    label <- future$label
    if (is.null(label)) label <- "<none>"
    stop(FutureError(sprintf("A future ('%s') can only be launched once.", label), future = future))
  }
  
  ## Assert that the process that created the future is
  ## also the one that evaluates/resolves/queries it.
  assertOwner(future)

  mcparallel <- importParallel("mcparallel")

  expr <- getExpression(future)
  envir <- future$envir

  reg <- sprintf("multicore-%s", session_uuid())
  requestCore(
    await = function() FutureRegistry(reg, action = "collect-first", earlySignal = TRUE),
    workers = future$workers
  )

  ## Add to registry
  FutureRegistry(reg, action = "add", future = future, earlySignal = TRUE)

  future.args <- list(expr)
  job <- do.call(parallel::mcparallel, args = future.args, envir = envir)

  future$job <- job
  future$state <- "running"

  if (debug) mdebugf("%s started", class(future)[1])
  
  invisible(future)
}

#' @export
resolved.MulticoreFuture <- function(x, run = TRUE, timeout = 0.2, ...) {
  ## A lazy future not even launched?
  if (x$state == "created") {
    if (run) {
      ## If free cores are available, then launch this lazy future
      if (x$workers > usedCores()) x <- run(x)
    }
    return(FALSE)
  }

  ## Is value already collected?
  if (!is.null(x$result)) {
    ## Signal conditions early?
    signalEarly(x, ...)
    return(TRUE)
  }

  ## Assert that the process that created the future is
  ## also the one that evaluates/resolves/queries it.
  assertOwner(x)

  job <- x$job
  stop_if_not(inherits(job, "parallelJob"))

  selectChildren <- importParallel("selectChildren")
  
  ## NOTE: We cannot use mcollect(job, wait = FALSE, timeout = 0.2),
  ## because that will return NULL if there's a timeout, which is
  ## an ambigous value because the future expression may return NULL.
  ## WORKAROUND: Adopted from parallel::mccollect().
  ## FIXME: Can we use result() instead? /HB 2018-07-16
  pid <- selectChildren(children = job, timeout = timeout)
  res <- (is.integer(pid) || is.null(pid))

  ## Collect and relay immediateCondition if they exists
  conditions <- readImmediateConditions(signal = TRUE)
  ## Record conditions as signaled
  signaled <- c(x$.signaledConditions, conditions)
  x$.signaledConditions <- signaled

  ## Signal conditions early? (happens only iff requested)
  if (res) signalEarly(x, ...)

  res
}


#' @export
result.MulticoreFuture <- function(future, ...) {
  ## Has the result already been collected?
  result <- future$result
  if (!is.null(result)) {
    if (inherits(result, "FutureError")) stop(result)
    return(result)
  }

  if (future$state == "created") {
    future <- run(future)
  }

  ## Assert that the process that created the future is
  ## also the one that evaluates/resolves/queries it.
  assertOwner(future)

  ## If not, wait for process to finish, and
  ## then collect and record the value
  mccollect <- importParallel("mccollect")
  job <- future$job
  stop_if_not(inherits(job, "parallelJob"))

  ## WORKAROUNDS for R (< 3.6.0):
  ##  1. Pass single job as list, cf.
  ##     https://bugs.r-project.org/bugzilla3/show_bug.cgi?id=17413
  jobs <- if (getRversion() >= "3.6.0") job else list(job)
  
  result <- mccollect(jobs = jobs, wait = TRUE)[[1L]]
  
  ## NOTE: In Issue #218 it was suggested that parallel:::rmChild() could
  ## fix this, but there seems to be more to this story, because we still
  ## get some of those warning even after removing children here.
  rmChild <- importParallel("rmChild")
  rmChild(child = job)

  ## Sanity checks
  if (!inherits(result, "FutureResult")) {
    ## SPECIAL: Check for fallback 'fatal error in wrapper code'
    ## try-error from parallel:::mcparallel().  If detected, then
    ## turn into an error with a more informative error message, cf.
    ## https://github.com/HenrikBengtsson/future/issues/35
    if (identical(result, structure("fatal error in wrapper code", class = "try-error"))) {
      label <- future$label
      if (is.null(label)) label <- "<none>"
      msg <- result
      ex <- FutureError(sprintf("Detected an error (%s) by the 'parallel' package while trying to retrieve the value of a %s (%s). This could be because the forked R process that evaluates the future was terminated before it was completed: %s", sQuote(msg), class(future)[1], sQuote(label), sQuote(hexpr(future$expr))), future = future)
    } else if (is.null(result)) {
      label <- future$label
      if (is.null(label)) label <- "<none>"

      pid <- job$pid
      pid_info <- if (is.numeric(pid)) sprintf("PID %g", pid) else NULL

      info <- pid_info
      msg <- sprintf("Failed to retrieve the result of %s (%s) from the forked worker (on localhost; %s)", class(future)[1], label, info)

      ## POST-MORTEM ANALYSIS:
      postmortem <- list()
    
      ## (a) Did a localhost worker process terminate?
      if (is.numeric(pid)) {
        alive <- pid_exists(pid)
        if (is.na(alive)) {
          msg2 <- "Failed to determined whether a process with this PID exists or not, i.e. cannot infer whether the forked localhost worker is alive or not."
        } else if (alive) {
          msg2 <- "A process with this PID exists, which suggests that the forked localhost worker is still alive."
        } else {
          msg2 <- "No process exists with this PID, i.e. the forked localhost worker is no longer alive."
        }
        postmortem$alive <- msg2
      }

      postmortem <- unlist(postmortem, use.names = FALSE)
      if (!is.null(postmortem)) {
         postmortem <- sprintf("Post-mortem diagnostic: %s",
                               paste(postmortem, collapse = ". "))
         msg <- paste0(msg, ". ", postmortem)
      }

      ex <- FutureError(msg, future = future)
    } else {
      ex <- UnexpectedFutureResultError(future)
    }
    future$result <- ex
    stop(ex)
  }

  ## Collect and relay immediateCondition if they exists
  conditions <- readImmediateConditions()
  ## Record conditions as signaled
  signaled <- c(future$.signaledConditions, conditions)
  future$.signaledConditions <- signaled

  ## Record conditions
  result$conditions <- c(result$conditions, signaled)
  signaled <- NULL
  
  future$result <- result

  future$state <- "finished"

  ## Remove from registry
  reg <- sprintf("multicore-%s", session_uuid())
  FutureRegistry(reg, action = "remove", future = future, earlySignal = TRUE)
  
  ## Always signal immediateCondition:s and as soon as possible.
  ## They will always be signaled if they exist.
  signalImmediateConditions(future)

  result
}


#' @export
getExpression.MulticoreFuture <- function(future, expr = future$expr, mc.cores = 1L, immediateConditions = TRUE, conditionClasses = future$conditions, resignalImmediateConditions = getOption("future.multicore.relay.immediate", immediateConditions), ...) {
  ## Assert that no arguments but the first is passed by position
  assert_no_positional_args_but_first()

  debug <- getOption("future.debug", FALSE)

  ## Disable multithreading?
  ## Disable multi-threading in futures?
  multithreading <- Sys.getenv("R_FUTURE_FORK_MULTITHREADING_ENABLE", "TRUE")
  multithreading <- isTRUE(as.logical(multithreading))
  multithreading <- getOption("future.fork.multithreading.enable", multithreading)
  if (isFALSE(multithreading) &&
      !supports_omp_threads(assert = TRUE, debug = debug)) {
    warning(FutureWarning("It is not possible to disable multi-threading on this systems", future = future))
    multithreading <- TRUE
  }
  
  if (isFALSE(multithreading)) {
    expr <- bquote({
      ## Force single-threaded OpenMP, iff needed
      old_omp_threads <- RhpcBLASctl::omp_get_max_threads()
      if (old_omp_threads > 1L) {
        RhpcBLASctl::omp_set_num_threads(1L)
        base::on.exit(RhpcBLASctl::omp_set_num_threads(old_omp_threads), add = TRUE)
        new_omp_threads <- RhpcBLASctl::omp_get_max_threads()
        if (!is.numeric(new_omp_threads) || is.na(new_omp_threads) || new_omp_threads != 1L) {
          label <- future$label
          if (is.null(label)) label <- "<none>"
          warning(future::FutureWarning(sprintf("Failed to force a single OMP thread on this system. Number of threads used: %s", new_omp_threads), future = future))
        }
      }

      ## Tell BLAS to use a single thread(?)
      ## NOTE: Is multi-threaded BLAS an issue? Have we got any reports on this.
      ## FIXME: How can we get the current BLAS settings?
      ## /HB 2020-01-09
      ## RhpcBLASctl::blas_set_num_threads(1L)

      .(expr)
    })
    
    if (debug) mdebug("- Updated expression to force single-threaded mode")
  }


  ## Inject code for resignaling immediateCondition:s?
  if (resignalImmediateConditions && immediateConditions) {
    immediateConditionClasses <- getOption("future.relay.immediate", "immediateCondition")
    conditionClasses <- unique(c(conditionClasses, immediateConditionClasses))

    if (length(conditionClasses) > 0L) {
      ## Communicate via the local file system
      expr <- bquote({
        withCallingHandlers({
          .(expr)
        }, immediateCondition = function(cond) {
          ## Send condition wrapped in an object with a timestamp
          obj <- list(time = Sys.time(), condition = cond)
          file <- tempfile(
            class(cond)[1],
            tmpdir = .(immediateConditionsPath()),
            fileext = ".rds"
          )
          ## save_rds <- future:::save_rds
          save_rds <- .(save_rds)
          save_rds(obj, file)

          ## Avoid condition from being signaled more than once
          ## muffleCondition <- future:::muffleCondition
          muffleCondition <- .(muffleCondition)
          muffleCondition(cond)
        })
      })
    } ## if (length(conditionClasses) > 0)
  } ## if (resignalImmediateConditions && immediateConditions)

  NextMethod(expr = expr, mc.cores = mc.cores, immediateConditions = immediateConditions, conditionClasses = conditionClasses)
}
