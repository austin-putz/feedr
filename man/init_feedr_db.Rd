\name{init_feedr_db}
\alias{init_feedr_db}
\title{Initialize a feedr database session}
\usage{
init_feedr_db(path = NULL, seed = FALSE, migrate = FALSE, read_only = FALSE)
}
\arguments{
\item{path}{Path to the \code{.db} file.}

\item{seed}{If \code{TRUE}, seed example data into a new empty database.}

\item{migrate}{If \code{TRUE}, run pending schema migrations automatically.}

\item{read_only}{Open in read-only mode.}
}
\value{
A \code{feedr_session} object.
}
\description{
Initialize a feedr database session.
}
