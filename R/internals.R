# These functions are only used internally in the package, so there is no need for documenting them.
#' @importFrom stats model.frame
#' @importFrom stats model.matrix
#' @importFrom Matrix Matrix
#' @importFrom stats delete.response
#' @importFrom stats summary.glm
#' @importFrom stats contrasts

# Selection model object
internal_selection <- function(X,
                               X_nons,
                               X_rand,
                               weights,
                               weights_rand,
                               R,
                               method_selection,
                               optim_method,
                               h = h,
                               est_method,
                               maxit,
                               varcov = FALSE,
                               ...) {

  estimation_method <- get_method(est_method)
  estimation_method$model_selection(X,
                                    X_nons,
                                    X_rand,
                                    weights,
                                    weights_rand,
                                    R,
                                    method_selection,
                                    optim_method,
                                    h = h,
                                    est_method,
                                    maxit,
                                    varcov,
                                    ...)

}
# Outcome model object
internal_outcome <- function(X_nons,
                             X_rand,
                             y,
                             weights,
                             family_outcome,
                             pop_totals = FALSE) {

  # estimation
  model_nons <- nonprobMI_fit(x = X_nons,
                              y = y,
                              weights = weights,
                              family_outcome = family_outcome)


  model_nons_coefs <- model_nons$coefficients
  parameters_statistics <- stats::summary.glm(model_nons)$coefficients

  if (pop_totals) {
    y_rand_pred <- sum(X_rand * model_nons_coefs)
  } else {
     y_rand_pred <-  as.numeric(X_rand %*% model_nons_coefs) # y_hat for probability sample
  }
  y_nons_pred <- as.numeric(X_nons %*% model_nons_coefs)

  list(y_rand_pred = y_rand_pred,
       y_nons_pred = y_nons_pred,
       model_nons_coefs = model_nons_coefs,
       parameters_statistics = parameters_statistics)

}
theta_h_estimation <- function(R,
                               X,
                               weights_rand,
                               weights,
                               h,
                               method_selection,
                               maxit,
                               pop_totals = NULL,
                               pop_means = NULL){

  p <- ncol(X)
  start0 <- start_fit(X = X,
                      R = R,
                      weights = weights,
                      weights_rand = weights_rand,
                      method_selection = method_selection)
  start0 <- rep(0, p)
  # theta estimation by unbiased estimating function depending on the h_x function TODO
  u_theta <- u_theta(R = R,
                     X = X,
                     weights = c(weights_rand, weights),
                     h = h,
                     method_selection = method_selection,
                     pop_totals = pop_totals)

  u_theta_der <- u_theta_der(R = R,
                             X = X,
                             weights = c(weights_rand, weights),
                             h = h,
                             method_selection = method_selection,
                             pop_totals = pop_totals)


  for (i in 1:maxit) {
    start <- start0 + MASS::ginv(u_theta_der(start0)) %*% u_theta(start0) # consider solve function
    if (sum(abs(start - start0)) < 0.001) break;
    if (sum(abs(start - start0)) > 1000) break;
    start0 <- start
  }
  theta_h <- as.vector(start)
  grad = u_theta(theta_h)
  hess = u_theta_der(theta_h)

  list(theta_h = theta_h,
       hess = hess,
       grad = grad,
       variance_covariance = solve(hess))
}
# Variance for inverse probability weighted estimator
internal_varIPW <- function(X_nons,
                            X_rand,
                            y_nons,
                            ps_nons,
                            mu_hat,
                            hess,
                            ps_nons_der,
                            N,
                            est_ps_rand,
                            ps_rand,
                            est_ps_rand_der,
                            n_rand,
                            pop_size,
                            method_selection,
                            est_method,
                            theta,
                            h,
                            var_cov1 = var_cov1,
                            var_cov2 = var_cov2) {

  eta <- as.vector(X_nons %*% as.matrix(theta))
  method <- get_method(method_selection)
  b_obj <- method$b_vec_ipw(X = X_nons,
                            ps = ps_nons,
                            psd = ps_nons_der,
                            y = y_nons,
                            mu = mu_hat,
                            hess = hess,
                            eta = eta,
                            pop_size = pop_size)
  b <- b_obj$b
  hess_inv <- b_obj$hess_inv

  # sparse matrix
  b_vec <- cbind(-1, b)
  H_mx <- cbind(0, N * hess_inv)
  sparse_mx <- Matrix::Matrix(rbind(b_vec, H_mx), sparse = TRUE)

  V1 <- var_cov1(X = X_nons,
                 y = y_nons,
                 mu = mu_hat,
                 ps = ps_nons,
                 psd = ps_nons_der,
                 pop_size = pop_size,
                 est_method = est_method,
                 h = h) # fixed
  V2 <- var_cov2(X = X_rand,
                 eps = est_ps_rand,
                 ps = ps_rand,
                 psd = est_ps_rand_der,
                 n = n_rand,
                 N = N,
                 est_method = est_method,
                 h = h)

  # variance-covariance matrix for set of parameters (mu_hat and theta_hat)
  V_mx_nonprob <- sparse_mx %*% V1 %*% t(as.matrix(sparse_mx)) # nonprobability component
  V_mx_prob <- sparse_mx %*% V2 %*% t(as.matrix(sparse_mx)) # probability component
  V_mx <- V_mx_nonprob + V_mx_prob

  var_nonprob <- as.vector(V_mx_nonprob[1,1])
  var_prob <- as.vector(V_mx_prob[1,1])
  var <- as.vector(V_mx[1,1])
  # vector of variances for theta_hat
  theta_hat_var <- diag(as.matrix(V_mx[2:ncol(V_mx), 2:ncol(V_mx)]))

  list(var_nonprob = var_nonprob,
       var_prob = var_prob,
       var = var,
       theta_hat_var = theta_hat_var)
}
# Variance for doubly robust estimator
internal_varDR <- function(OutcomeModel,
                           SelectionModel,
                           y_nons_pred,
                           method_selection,
                           theta,
                           ps_nons,
                           hess,
                           ps_nons_der,
                           est_ps_rand,
                           y_rand_pred,
                           N_nons,
                           est_ps_rand_der,
                           svydesign,
                           est_method,
                           h) {

  eta <- as.vector(SelectionModel$X_nons %*% as.matrix(theta))
  h_n <- 1/N_nons * sum(OutcomeModel$y_nons - y_nons_pred) # errors mean
  method <- get_method(method_selection)
  est_method <- get_method(est_method)
  #psd <- method$make_link_inv_der(eta)

  b <- method$b_vec_dr(X = SelectionModel$X_nons,
                       ps = ps_nons,
                       psd = ps_nons_der,
                       y = OutcomeModel$y_nons,
                       mu = mu_hat,
                       hess = hess,
                       eta = eta,
                       h_n = h_n,
                       y_pred = y_nons_pred)

  t <- est_method$make_t(X = SelectionModel$X_rand,
                         ps = est_ps_rand,
                         psd = est_ps_rand_der,
                         b = b,
                         h = h,
                         y_rand = y_rand_pred,
                         y_nons = y_nons_pred,
                         N = N_nons,
                         method_selection = method_selection)
  # asymptotic variance by each propensity score method (nonprobability component)
  var_nonprob <- est_method$make_var_nonprob(ps = ps_nons,
                                             psd = ps_nons_der,
                                             y = OutcomeModel$y_nons,
                                             y_pred = y_nons_pred,
                                             h_n = h_n,
                                             X = SelectionModel$X_nons,
                                             b = b,
                                             N = N_nons,
                                             h = h,
                                             method_selection = method_selection)



  # design based variance estimation based on approximations of the second-order inclusion probabilities
  svydesign <- stats::update(svydesign,
                             t = t)
  svydesign_mean <- survey::svymean(~t, svydesign) #perhaps using survey package to compute prob variance
  var_prob <- as.vector(attr(svydesign_mean, "var"))

  list(var_prob = var_prob,
       var_nonprob = var_nonprob)
}
# create an object with model frames and matrices to preprocess
model_frame <- function(formula, data, weights = NULL, svydesign = NULL, pop_totals = NULL, pop_size = NULL) {

  if (!is.null(svydesign)) {
  XY_nons <- model.frame(formula, data)
  X_nons <- model.matrix(XY_nons, data) #matrix for nonprobability sample with intercept
  nons_names <- attr(terms(formula, data = data), "term.labels")
  if (all(nons_names %in% colnames(svydesign$variables))) {
    X_rand <- model.matrix(delete.response(terms(formula)), svydesign$variables) #matrix of probability sample with intercept
  } else {
    stop("variable names in data and svydesign do not match")
  }
  y_nons <- XY_nons[,1]
  outcome_name <- names(XY_nons)[1]

  list(X_nons = X_nons,
       X_rand = X_rand,
       nons_names = nons_names,
       y_nons = y_nons,
       outcome_name = outcome_name)

  } else if (!is.null(pop_totals)) { # TODO
    XY_nons <- model.frame(formula, data)
    dep_name <- names(XY_nons)[2] # name of the dependent variable
    #matrix for nonprobability sample with intercept
    X_nons <- model.matrix(XY_nons, data, contrasts.arg = list(klasa_pr = contrasts(as.factor(XY_nons[,dep_name]), contrasts = FALSE)))
    #X_nons <- model.matrix(XY_nons, data)
    #nons_names <- attr(terms(formula, data = data), "term.labels")
    nons_names <- colnames(X_nons)[-1]
    #pop_totals <- pop_totals[which(attr(X_nons, "assign") == 1)]
    if(all(nons_names %in% names(pop_totals))) { # pop_totals, pop_means defined such as in `calibrate` function
      pop_totals <- pop_totals[nons_names]
    } else {
      warning("Selection and population totals have different names.")
    }
    y_nons <- XY_nons[,1]
    outcome_name <- names(XY_nons)[1]

    list(X_nons = X_nons,
         pop_totals = pop_totals,
         nons_names = nons_names,
         y_nons = y_nons,
         outcome_name = outcome_name)
  }
}
# Function for getting function from the selected method
get_method <- function(method) {
  if (is.character(method)) {
    method <- get(method, mode = "function", envir = parent.frame())
  }
  if (is.function(method)) {
    method <- method()
  }
  method
}

# summary helper functions
# for now just a rough sketch
specific_summary_info <- function(object, ...) {
  UseMethod("specific_summary_info")
}

specific_summary_info.nonprobsvy_ipw <- function(object,
                                                 ...) {
  res <- list(
    theta = object$parameters
  )

  attr(res$theta, "glm") <- TRUE
  attr(res, "TODO")     <- c("glm regression on selection variable")

  res
}

specific_summary_info.nonprobsvy_mi <- function(object,
                                                ...) {
  # TODO
}

specific_summary_info.nonprobsvy_dr <- function(object,
                                                ...) {
  res <- list(
    theta = object$parameters,
    beta  = object$beta
  )

  attr(res$beta,  "glm") <- TRUE
  attr(res$theta, "glm") <- TRUE
  attr(res, "TODO")     <- c("glm regression on selection variable",
                             "glm regression on outcome variable")

  res
}
