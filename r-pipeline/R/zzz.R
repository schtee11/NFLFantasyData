.onAttach <- function(libname, pkgname) {
  packageStartupMessage("dynmod ", utils::packageVersion("dynmod"),
                        " — ", SCORING$scheme)
}
