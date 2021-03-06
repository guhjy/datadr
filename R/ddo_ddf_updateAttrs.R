#' Update Attributes of a 'ddo' or 'ddf' Object
#'
#' Update attributes of a 'ddo' or 'ddf' object
#'
#' @param obj an object of class 'ddo' or 'ddf'
#' @param control parameters specifying how the backend should handle things (most-likely parameters to \code{rhwatch} in RHIPE) - see \code{\link{rhipeControl}}
#'
#' @return an object of class 'ddo' or 'ddf'
#'
#' @details This function looks for missing attributes related to a ddo or ddf (distributed data object or data frame) object and runs MapReduce to update them.  These attributes include "splitSizeDistn", "keys", "nDiv", "nRow", and "splitRowDistn".  These attributes are useful for subsequent computations that might rely on them.  The result is the input modified to reflect the updated attributes, and thus it should be used as \code{obj <- updateAttributes(obj)}.
#'
#' @author Ryan Hafen
#'
#' @references Bennett, Janine, et al. "Numerically stable, single-pass, parallel statistics algorithms.' Cluster Computing and Workshops", 2009. \emph{CLUSTER09. IEEE International Conference on.} IEEE, 2009
#'
#' @seealso \code{\link{ddo}}, \code{\link{ddf}}, \code{\link{divide}}
#'
#' @export
updateAttributes <- function(obj, control = NULL) {
  # obj <- ddf(iris)

  if(inherits(obj, "transformed")) {
    stop("Cannot run updateAttributes() on a transformed divided data object.", call. = FALSE)
  }

  ddoVars <- requiredObjAttrs(obj)$ddo
  ddfVars <- requiredObjAttrs(obj)$ddf

  needList <- c(getAttrNeedList(obj, "ddf"), getAttrNeedList(obj, "ddo"))

  # needList["keys"] <- !hasAttributes(obj, "keys")

  implemented <- getDr("implementedAttrVars")
  needList <- needList[names(needList) %in% implemented]

  if(any(needList)) {

    # TODO: for categorical data, in addition to tabulating, also emit a unique key
    # of form "varname_level" for each observation -- each unique 'level' will be
    # tallied in reduce$pre using counter("varname_level", 1)
    # this will allow for counting unique levels of a qualitative variable that has
    # a very large number of levels (millions+)

    message("* Running map/reduce to get missing attributes...")
    map <- expression({
      for(i in seq_along(map.values)) {
        k <- map.keys[[i]]
        r <- map.values[[i]]

        ### ddo
        objSize <- as.numeric(object.size(r))
        if(needs["splitSizeDistn"]) collect("splitSizeDistn", objSize)
        if(needs["totObjectSize"]) collect("totObjectSize", objSize)
        if(needs["keys"]) collect("keys", k)
        if(needs["nDiv"]) collect("nDiv", 1.0)
        ### ddf
        # only apply transFn *after* ddo attrs have been computed
        if(!is.null(transFn)) {
          r <- kvApply(transFn, list(k, r))

        }
        if(!is.na(needs["nRow"])) {
          if(needs["nRow"])
            collect("nRow", nrow(r))
        }
        if(!is.na(needs["splitRowDistn"])) {
          if(needs["splitRowDistn"])
            collect("splitRowDistn", nrow(r))
        }
        if(!is.na(needs["summary"])) {
          if(needs["summary"]) {
            dfNames <- names(r)
            quantTypes <- c("integer", "numeric", "double")
            categTypes <- c("character", "factor")
            datetimeTypes <- c("POSIXct", "Date")

            for(i in seq_along(r)) {
              var <- r[[i]]
              if(inherits(var, quantTypes)) {
                if(all(is.na(var)) || length(var) == 0) {
                  minVal <- NA
                  maxval <- NA
                } else {
                  minVal <- min(var, na.rm = TRUE)
                  maxVal <- max(var, na.rm = TRUE)
                }

                collect(paste("summary_quant_", dfNames[i], sep = "_"), list(
                  nna = length(which(is.na(r[[i]]))),
                  moments = calculateMoments(r[[i]], order = 4),
                  min = minVal,
                  max = maxVal
                ))
              } else if(inherits(var, categTypes)) {
                collect(paste("summary_categ_", dfNames[i], sep = "_"), list(
                  nna = length(which(is.na(var))),
                  freqTable = tabulateMap(~ var, data = data.frame(var))
                ))
              } else if(inherits(var, datetimeTypes)) {
                if(all(is.na(var)) || length(var) == 0) {
                  minVal <- NA
                  maxval <- NA
                } else {
                  minVal <- min(var, na.rm = TRUE)
                  maxVal <- max(var, na.rm = TRUE)
                }

                collect(paste("summary_datetime_", dfNames[i], sep = "_"), list(
                  nna = length(which(is.na(r[[i]]))),
                  min = minVal,
                  max = maxVal
                ))
              }
            }
          }
        }
      }
    })

    reduce <- expression(
      pre = {
        ### ddo
        splitSizeDistn <- NULL
        keys <- NULL
        nDiv <- as.numeric(0)
        totObjectSize <- as.numeric(0)
        ### ddf
        nRow <- as.numeric(0)
        splitRowDistn <- NULL
        ### ddf summary
        resQuant <- list(nna = NULL, moments = NULL, min = NULL, max = NULL)
        resCateg <- list(nna = NULL, freqTable = NULL)
        resDatetime <- list(nna = NULL, min = NULL, max = NULL)
      },
      reduce = {
        ### ddo
        if(reduce.key == "splitSizeDistn")
          splitSizeDistn <- c(splitSizeDistn, do.call(c, reduce.values))
        if(reduce.key == "totObjectSize")
          totObjectSize <- totObjectSize + sum(do.call(c, reduce.values))
        if(reduce.key == "keys")
          keys <- c(keys, reduce.values)
        if(reduce.key == "nDiv")
          nDiv <- nDiv + sum(unlist(reduce.values), na.rm = TRUE)

        ### ddf
        if(reduce.key == "nRow")
          nRow <- nRow + sum(unlist(reduce.values), na.rm = TRUE)
        if(reduce.key == "splitRowDistn")
          splitRowDistn <- c(splitRowDistn, do.call(c, reduce.values))

        ### ddf summary
        if(grepl("^summary_quant", reduce.key)) {
          curMomList <- lapply(reduce.values, function(x) x$moments)
          if(!is.null(resQuant$moments))
            curMomList <- c(list(resQuant$moments), curMomList)

          resQuant$nna     <- sum(c(resQuant$nna, sapply(reduce.values, function(x) x$nna)), na.rm = TRUE)
          resQuant$moments  <- do.call(combineMultipleMoments, curMomList)
          resQuant$min     <- min(c(resQuant$min, sapply(reduce.values, function(x) x$min)), na.rm = TRUE)
          resQuant$max     <- max(c(resQuant$max, sapply(reduce.values, function(x) x$max)), na.rm = TRUE)
        }

        if(grepl("^summary_categ", reduce.key)) {
          resCateg$nna     <- sum(c(resCateg$nna, sapply(reduce.values, function(x) x$nna)), na.rm=TRUE)
          resCateg$freqTable <- tabulateReduce(resCateg$freqTable, lapply(reduce.values, function(x) x$freqTable), maxUnique = 10000)
        }

        if(grepl("^summary_datetime", reduce.key)) {
          resDatetime$nna     <- sum(c(resDatetime$nna, sapply(reduce.values, function(x) x$nna)), na.rm = TRUE)
          tmp <- c(list(resDatetime$min), lapply(reduce.values, function(x) x$min))
          tmp <- tmp[!sapply(tmp, is.null)]
          resDatetime$min     <- min(do.call(c, tmp), na.rm = TRUE)
          tmp <- lapply(reduce.values, function(x) x$max)
          tmp <- tmp[!sapply(tmp, is.null)]
          resDatetime$max     <- max(do.call(c, tmp), na.rm = TRUE)
        }
      },
      post = {
        ### ddo
        if(reduce.key == "splitSizeDistn")
          collect("splitSizeDistn",
            quantile(splitSizeDistn, probs = seq(0, 1, by = 0.01), na.rm = TRUE))
        if(reduce.key == "totObjectSize")
          collect("totObjectSize", totObjectSize)
        if(reduce.key == "keys")
          collect("keys", keys)
        if(reduce.key == "nDiv")
          collect("nDiv", nDiv)

        ### ddf
        if(reduce.key == "splitRowDistn")
          collect("splitRowDistn",
            quantile(splitRowDistn, probs = seq(0, 1, by = 0.01), na.rm = TRUE))
        if(reduce.key == "nRow")
          collect("nRow", nRow)

        ### ddf summary
        if(grepl("^summary_quant", reduce.key))
          collect(reduce.key, resQuant)

        if(grepl("^summary_categ", reduce.key))
          collect(reduce.key, resCateg)

        if(grepl("^summary_datetime", reduce.key))
          collect(reduce.key, resDatetime)
      }
    )

    parList <- list(
      needs = needList,
      transFn = getAttribute(obj, "transFn"),
      libPaths = .libPaths()
    )

    if(! "package:datadr" %in% search()) {
      message("* ---- running dev version - sending datadr functions to mr job")
      parList <- c(parList, list(
        calculateMoments     = calculateMoments,
        tabulateMap        = tabulateMap,
        combineMultipleMoments = combineMultipleMoments,
        combineMoments      = combineMoments,
        tabulateReduce      = tabulateReduce,
        kvApply           = kvApply
      ))

      setup <- expression({
        suppressWarnings(suppressMessages(require(data.table)))
      })
    } else {
      setup <- expression({
        suppressWarnings(suppressMessages(require(datadr)))
      })
    }

    tmp <- mrExec(
      obj,
      setup = setup,
      map = map,
      reduce = reduce,
      params = parList,
      verbose = FALSE,
      control = control
    )

    # result is kvMemory - get the k/v pairs (stored in conn)
    tmp <- getAttribute(tmp, "conn")$data

    tmpNames <- sapply(tmp, "[[", 1)

    ddoInd <- which(tmpNames %in% ddoVars)
    ddfInd <- which(tmpNames %in% ddfVars)
    hasSummary <- any(grepl("^summary", tmpNames))

    # get the result into the right form for setAttributes
    notSummaryInd <- which(!grepl("^summary", tmpNames))
    attrNames <- sapply(tmp[notSummaryInd], "[[", 1)
    attrs <- lapply(tmp[notSummaryInd], "[[", 2)
    names(attrs) <- attrNames

    # if there is a summary, get it into good form
    if(hasSummary) {
      summaryList <- list()
      summaryInd <- which(grepl("^summary", tmpNames))
      for(i in summaryInd) {
        k <- tmp[[i]][[1]]
        v <- tmp[[i]][[2]]
        varType <- gsub("^summary_(quant|categ|datetime).*", "\\1", k)
        varName <- gsub("^summary_(quant|categ|datetime)__(.*)", "\\2", k)
        if(varType == "quant") {
          stats <- moments2statistics(v$moments)
          v <- list(nna = v$nna, stats = stats, range = c(v$min, v$max))
          class(v) <- c("ddfSummNumeric", "list")
          summaryList[[varName]] <- v
        } else if(varType == "categ") {
          class(v) <- c("ddfSummFactor", "list")
          # were there more unique levels than we could handle?
          v$complete <- attrs[["nRow"]] == sum(v$freqTable$Freq) + v$nna
          names(v$freqTable)[1] <- "value"
          summaryList[[varName]] <- v
        } else if(varType == "datetime") {
          v <- list(nna = v$nna, range = c(v$min, v$max))
          class(v) <- c("ddfSummDatetime", "list")
          summaryList[[varName]] <- v
        }
      }

      # make sure it is in the same order as the columns
      summaryList <- summaryList[intersect(names(obj), names(summaryList))]

      class(summaryList) <- c("ddfSummary", "list")
      attrs[["summary"]] <- summaryList
    }

    # add keyHashes (used for extraction)
    # if(needList["keyHashes"])
    if(!is.null(attrs$keys))
      attrs$keyHashes <- as.character(sapply(attrs$keys, digest))

    obj <- setAttributes(obj, attrs)

    return(obj)
  } else {
    message("All (implemented) attributes have already been computed.")
    return(obj)
  }
}




