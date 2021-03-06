% Generated by roxygen2: do not edit by hand
% Please edit documentation in R/Interpolate.R
\name{as.path}
\alias{as.path}
\title{Interpolates between locations}
\usage{
as.path(x, y, n = 10, path = TRUE)
}
\arguments{
\item{x, y}{numeric vectors of x and y locations. If one of them is of length 1,
if will be recycled.}

\item{n}{number of points to interpolate to}

\item{path}{either \code{TRUE} of a character vector with the name of the path.}
}
\value{
A list of components \code{x} and \code{y} with the list of locations and the \code{path}
arguments
}
\description{
This is a helper function to quickly make an interpolated list of locations
between a number of locations
}
\details{
This function is mostly useful when combined with \link{Interpolate}
}
\seealso{
Interpolate
}
