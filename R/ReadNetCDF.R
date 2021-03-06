#' Read NetCDF files.
#'
#' Using the \code{\link[ncdf4]{ncdf4-package}} package, it reads a NetCDF file. The advantage
#' over using \code{\link[ncdf4]{ncvar_get}} is that the output is a tidy data.table
#' with proper dimensions.
#'
#' @param file file to read from.
#' @param vars a character vector with the name of the variables to read. If
#' \code{NULL}, then it read all the variables.
#' @param out character indicating the type of output desired
#' @param subset a named list a subsetting vectors. See Details.
#' @param key if `TRUE`, returns a data.table keyed by the dimensions of the data.
#'
#' @details
#' `subset` must be a named list for subsetting. Names must match dimensions
#' specified in the NetCDF file and each element must be a vector of the same type
#' of that dimension whose range will be use for subsetting. You don't need to
#' provide and exact range that matches the actual gridpoints of the file; the
#' closest gridpoint will be selected.
#'
#' @return
#' The return format is specified by `out`. It can be a data table in which each
#' column is a variable and each row, an observation; an array with named
#' dimensions; or a vector. Since it's possible to return multiple arrays or
#' vectors (one for each variable), for consistency the return type is always a
#' list. Either of these two options are much faster than the
#' first since the most time consuming part is the melting of the array
#' returned by [ncdf4::ncvar_get]. `out = "vector"` is particularly useful for
#' adding new variables to an existing data frame with the same dimensions.
#'
#' When not all variables specified in `vars` have the same number of dimensions,
#' the shorter variables will be recycled. E.g. if reading a 3D pressure field
#' and a 2D surface temperature field, the latter will be turned into a 3D field
#' with the same values in each missing dimension.
#'
#' `GlimpseNetCDF()` returns a list of variables and dimensions included in the
#' file with a nice printing method.
#'
#' @examples
#' \dontrun{
#' file <- "file.nc"
#' # Get a list of variables.
#' variables <- GlimpseNetCDF(file)
#' print(variables)
#'
#' # Read only the first one, with name "var".
#' field <- ReadNetCDF(file, vars = c(var = names(variables$vars[1])))
#' # Add a new variable.
#' # ¡Make sure it's on the same exact grid!
#' field[, var2 := ReadNerCDF(file2, out = "vector", subset = list(lat = 90:10))]
#' }
#'
#' @export
#' @importFrom lubridate years weeks days hours minutes seconds milliseconds ymd_hms
#' @import data.table
ReadNetCDF <- function(file, vars = NULL,
                       out = c("data.frame", "vector", "array"),
                       subset = NULL, key = FALSE) {
    ncdf4.available <- requireNamespace("ncdf4", quietly = TRUE)
    udunits2.available <- requireNamespace("udunits2", quietly = TRUE)
    if (!ncdf4.available & !udunits2.available) {
        stop("ReadNetCDF needs packages 'ncdf4' and 'udunits2'. ",
             "Install them with 'install.packages(c(\"ncdf4\", \"udunits2\"))'")
    }

    if (!ncdf4.available) {
        stop("ReadNetCDF needs package'ncdf4'. ",
             "Install it with 'install.packages(\"ncdf4\")'")
    }

    if (!udunits2.available) {
        stop("ReadNetCDF needs package 'udunits2'. ",
             "Install it with 'install.packages(\"udunits2\")'")
    }

    out <- out[1]
    checks <- makeAssertCollection()
    assertAccess(file, "r", add = checks)
    assertCharacter(vars, null.ok = TRUE, any.missing = FALSE, unique = TRUE,
                    add = checks)
    assertChoice(out, c("data.frame", "vector", "array", "vars"), add = checks)
    assertList(subset, types = c("vector", "POSIXct", "POSIXt", "Date"), null.ok = TRUE, add = checks)
    assertNamed(subset, c("unique"), add = checks)
    assertFlag(key, add = checks)

    reportAssertions(checks)

    ncfile <- ncdf4::nc_open(file)

    if (out[1] == "vars") {
        r <- list(vars = ncfile$var,
                  dims = ncfile$dim)
        class(r) <- c("nc_glimpse", class(r))
        # options(OutDec = dec)
        return(r)
    }


    dec <- getOption("OutDec")
    # Dejemos todo prolijo antes de salir.
    options(OutDec = ".")
    on.exit({
        options(OutDec = dec)
        ncdf4::nc_close(ncfile)
    })

    if (is.null(vars)) {
        vars <- names(ncfile$var)
    }

    # Vars must be a (fully) named vector.
    varnames <- names(vars)
    if (is.null(varnames)) {
        names(vars) <- vars
    } else {
        no.names <- nchar(varnames) == 0
        names(vars)[no.names] <- vars[no.names]
    }

    # Leo las dimensiones.
    dims <- names(ncfile$dim)
    # dims <- dims[dims != "nbnds"]
    ids <- vector()
    dimensions <- list()
    for (i in seq_along(dims)) {
        dimensions[[dims[i]]] <- ncfile$dim[[dims[i]]]$vals
        ids[i] <- ncfile$dim[[i]]$id
    }
    names(dims) <- ids
    has_timedate <- FALSE
    if ("time" %in% names(dimensions) && ncfile$dim$time$units != "") {
        has_timedate <- TRUE
        time <- udunits2::ud.convert(dimensions[["time"]],
                                     ncfile$dim$time$units,
                                     "seconds since 1970-01-01 00:00:00")
        dimensions[["time"]] <- as.character(as.POSIXct(time, tz = "UTC",
                                                        origin = "1970-01-01 00:00:00"))
    }

    # if (out[1] == "vars") {
    #     r <- list(vars = unname(vars), dimensions = dimensions, dims = dims)
    #     # options(OutDec = dec)
    #     return(r)
    # }

    ## Hago los subsets
    # Me fijo si faltan dimensiones
    subset.extra <- names(subset)[!(names(subset) %in% names(dimensions))]
    if (length(subset.extra) != 0) {
        stop(paste0("Subsetting dimensions not found: ",
                    paste0(subset.extra, collapse = ", "), "."))
    }

    # Leo las variables y las meto en una lista.
    nc <- list()
    nc_dim <- list()

    dim.length <- vector("numeric", length = length(vars))
    for (v in seq_along(vars)) {

        # Para cada variable, veo start y count
        order <- ncfile$var[[vars[v]]]$dimids
        start <- rep(1, length(order))
        names(start) <- names(dimensions[dims[as.character(order)]])
        count <- rep(-1, length(order))
        names(count) <- names(dimensions[dims[as.character(order)]])

        sub.dimensions <- dimensions

        for (s in names(subset)[names(subset) %in% names(start)]) {
            d <- dimensions[[s]]
            sub <- subset[[s]]

            if (.is.somedate(sub[1]) | s == "time") {
                start[[s]] <- which(lubridate::as_datetime(d) %~% min(lubridate::as_datetime(sub)))
                count[[s]] <- abs(which(lubridate::as_datetime(d) %~% max(lubridate::as_datetime(sub))) - start[[s]] + 1)
            } else {
                start1 <- which(d %~% sub[1])
                end <- which(d %~% sub[length(sub)])
                start[[s]] <- min(start1, end)
                count[[s]] <- abs(end - start1) + 1
            }

            if(count[[s]] == 0) count[[s]] <- 1

            sub.dimensions[[s]] <- dimensions[[s]][seq.int(start[[s]], start[[s]] + count[[s]] - 1)]
        }

        var1 <- ncdf4::ncvar_get(ncfile, vars[v], collapse_degen = FALSE, start = start,
                                 count = count)

        dimnames(var1) <- sub.dimensions[dims[as.character(order)]]
        dim.length[v] <- length(order)
        nc[[v]] <- var1
        nc_dim[[v]] <- as.vector(sub.dimensions[dims[as.character(order)]])
    }

    if (out[1] == "array") {
        return(nc)
    } else if (out[1] == "vector") {
        nc <- lapply(seq_along(nc), function(x) c(nc[[x]]))
        names(nc) <- names(vars)
        return(nc)
    } else {
        first.var <- which.max(dim.length)
        nc.df <- .melt_array(nc[[first.var]], dims = nc_dim[[first.var]],
                             value.name = names(vars)[first.var])

        if ("time" %in% names(dimensions) && has_timedate) {
            nc.df[, time2 := lubridate::as_datetime(time[1]), by = time]
            nc.df[, time := NULL]
            data.table::setnames(nc.df, "time2", "time")
        }

        for (v in seq_along(vars)[-first.var]) {
            this.dim <- names(dimnames(nc[[v]]))
            first.dim <- names(dimnames(nc[[first.var]]))
            missing.dim <- first.dim[!(first.dim %in% this.dim)]
            nc.df[, names(vars)[v] := c(nc[[v]]), by = c(missing.dim)]
        }

        if (key == TRUE) data.table::setkeyv(nc.df, names(nc.df)[!(names(nc.df) %in% names(vars))])
    }


    return(nc.df[])
}


#' @rdname ReadNetCDF
#'
#' @export
GlimpseNetCDF <- function(file) {
    ReadNetCDF(file, out = "vars")
}

#' @export
print.nc_glimpse <- function(x, ...) {
    cat("----- Variables ----- \n")
    x <- lapply(x$vars, print)

    cat("\n\n")
    cat("----- Dimensions ----- \n")
    x <- lapply(x$dim, print)
}

#' @export
print.ncvar4 <- function(x, ...) {
    cat(x$name, ":\n", sep = "")
    cat("    ", x$longname, sep = "")

    if (x$units != "") cat(" in ", x$units, sep = "")

    cat("\n")
    dims <- vapply(x$dim, function(x) x$name, "a")

    cat("    Dimensions: ")
    cat(paste0(dims, collapse = " by "), sep = "")
    cat("\n")

    return(invisible(x))
}

#' @export
print.ncdim4 <- function(x, ...) {
    # cat("$", dim$name, "\n", sep = "")
    if (x$name == "time" & x$units != "") {
        time <- udunits2::ud.convert(x$vals,
                                     x$units,
                                     "seconds since 1970-01-01 00:00:00")
        vals <- as.POSIXct(time, tz = "UTC", origin = "1970-01-01 00:00:00")
        units <- ""
    } else {
        vals <- x$vals
        units <- x$units
    }

    cat("  ", x$name, ": ",
        x$len, " values from ",
        as.character(min(vals)), " to ",
        as.character(max(vals)), " ",
        units,"\n", sep = "")
    return(invisible(x))
}


.melt_array <- function(array, dims, value.name = "V1") {
    dims <- lapply(dims, c)
    dims <- c(dims[length(dims):1], sorted = FALSE)
    grid <- do.call(data.table::CJ, dims)
    grid[, c(value.name) := c(array)][]

    return(grid)
}
