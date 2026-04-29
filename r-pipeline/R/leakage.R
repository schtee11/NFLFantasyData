#' Target-leakage audit — pearson correlations + lasso top features.
#'
#' Run BEFORE training any model. For each (position, target) pair:
#'
#'   1. Compute pearson correlation between every numeric feature and the
#'      target on the training data. Flag |r| >= `r_threshold` (default 0.95).
#'      Anything above this is suspicious — likely a feature that encodes
#'      the target itself (post-NFL info that snuck in, etc.).
#'
#'   2. Fit a lasso (glmnet alpha=1) feature → target. Print the top-K
#'      features by absolute coefficient magnitude. Eyeball them for plausibility.
#'
#' This function is read-only — it never modifies data. Output is a list
#' of audit reports, one per (position, target) combo. Print or save as
#' part of the Phase 2 Quarto report.
#'
#' @param features data.frame from prospect_features (training rows only).
#' @param targets named list: name → numeric vector of target values aligned
#'   with `features` rows. Names become target labels in the report.
#' @param positions character vector of positions to audit.
#' @param r_threshold absolute pearson correlation flagged as suspicious.
#' @param top_k how many lasso features to print per (pos, target).
#' @return list of per-(pos, target) audit results.
#' @export
leakage_audit <- function(features, targets,
                          positions = POSITIONS,
                          r_threshold = 0.95,
                          top_k = 10L) {
  stopifnot(is.data.frame(features), "pos" %in% names(features),
            is.list(targets))

  numeric_feats <- names(features)[vapply(features, is.numeric, logical(1))]
  numeric_feats <- setdiff(numeric_feats, c("draft_year"))

  out <- list()
  for (p in positions) {
    rows <- which(features$pos == p)
    if (length(rows) < 30L) {
      log_warn("leakage_audit: pos={p} has only {length(rows)} rows; skipping")
      next
    }
    f_pos <- features[rows, numeric_feats, drop = FALSE]

    for (tname in names(targets)) {
      y <- targets[[tname]][rows]
      keep <- !is.na(y)
      if (sum(keep) < 30L) next
      yk <- y[keep]
      Xk <- f_pos[keep, , drop = FALSE]

      # Pearson correlations
      cors <- vapply(Xk, function(col) {
        if (sum(!is.na(col)) < 10L) return(NA_real_)
        suppressWarnings(stats::cor(col, yk, use = "pairwise.complete.obs"))
      }, numeric(1))
      cors_df <- data.frame(
        feature = names(cors),
        r       = round(unname(cors), 4),
        flagged = !is.na(cors) & abs(cors) >= r_threshold
      )
      cors_df <- cors_df[order(-abs(cors_df$r)), ]
      cors_df <- cors_df[!is.na(cors_df$r), ]

      # Lasso top-K features (only if glmnet available)
      lasso_top <- .lasso_top_features(Xk, yk, top_k = top_k)

      key <- paste(p, tname, sep = ":")
      out[[key]] <- list(
        pos        = p,
        target     = tname,
        n          = sum(keep),
        cor_table  = cors_df,
        flagged    = cors_df$feature[cors_df$flagged],
        lasso_top  = lasso_top
      )
    }
  }
  out
}

.lasso_top_features <- function(X, y, top_k = 10L) {
  if (!requireNamespace("glmnet", quietly = TRUE)) {
    log_warn("glmnet not installed — skipping lasso step (correlations only)")
    return(NULL)
  }
  # need a complete-case matrix for glmnet
  X_mat <- as.matrix(X)
  X_mat[is.na(X_mat)] <- 0  # crude but prevents row drops; lasso shrinks zeros
  if (nrow(X_mat) < 30L || ncol(X_mat) < 2L) return(NULL)
  fit <- tryCatch(
    glmnet::cv.glmnet(X_mat, y, alpha = 1, nfolds = 5),
    error = function(e) {
      log_warn("lasso fit failed: {conditionMessage(e)}")
      NULL
    }
  )
  if (is.null(fit)) return(NULL)
  coefs <- as.matrix(stats::coef(fit, s = "lambda.min"))
  coefs <- coefs[rownames(coefs) != "(Intercept)", , drop = FALSE]
  ord <- order(-abs(coefs[, 1]))
  ord <- ord[seq_len(min(top_k, length(ord)))]
  data.frame(
    feature = rownames(coefs)[ord],
    coef    = round(coefs[ord, 1], 4),
    row.names = NULL
  )
}

#' Pretty-print a leakage audit result.
#' @export
print_leakage_audit <- function(audit) {
  for (key in names(audit)) {
    a <- audit[[key]]
    cat(sprintf("\n=== %s | n=%d ===\n", key, a$n))
    cat("  top |r| with target:\n")
    print(utils::head(a$cor_table, 8L), row.names = FALSE)
    if (length(a$flagged)) {
      cat(sprintf("  ⚠ FLAGGED (|r| >= 0.95): %s\n",
                  paste(a$flagged, collapse = ", ")))
    } else {
      cat("  ✓ no features flagged\n")
    }
    if (!is.null(a$lasso_top)) {
      cat("  lasso top-K:\n")
      print(a$lasso_top, row.names = FALSE)
    }
  }
  invisible(audit)
}
