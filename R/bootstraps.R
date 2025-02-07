# These functions are only used internally, so there is no need for documenting them
#' @importFrom survey as.svrepdesign

bootMI <- function(X_rand,
                   X_nons,
                   weights,
                   y,
                   family_outcome,
                   num_boot,
                   weights_rand,
                   mu_hat,
                   svydesign,
                   rep_type,
                   ...
                   ){

  mu_hats <- vector(mode = "numeric", length = num_boot)
  n_nons <- nrow(X_nons)
  n_rand <- nrow(X_rand)
  N <- sum(weights_rand)
  rep_weights <- survey::as.svrepdesign(svydesign, type = rep_type, replicates = num_boot)$repweights$weights
  k <- 1

  while (k <= num_boot) {

    strap <- sample.int(replace = TRUE, n = n_nons)
    weights_strap <- weights[strap]
    X_nons_strap <- X_nons[strap,]
    y_strap <- y[strap]

    #using svy package
    strap_rand_svy <- which(rep_weights[,k] != 0)
    weights_rand_strap_svy <- rep_weights[,k] * weights_rand


    model_strap <- nonprobMI_fit(x = X_nons_strap,
                                 y = y_strap,
                                 weights = weights_strap,
                                 family_outcome = family_outcome)

    beta <- model_strap$coefficients

    ystrap_rand <- as.numeric(X_rand %*% beta)

    mu_hat_boot <- mu_hatMI(ystrap_rand, weights_rand_strap_svy, N)
    mu_hats[k] <- mu_hat_boot
    k <- k + 1
  }

  boot_var <- 1/num_boot * sum((mu_hats - mu_hat)^2)
  boot_var
}

bootIPW <- function(X_rand,
                    X_nons,
                    weights,
                    y,
                    R,
                    theta_hat,
                    family_outcome,
                    num_boot,
                    weights_rand,
                    mu_hat,
                    method_selection,
                    n_nons,
                    n_rand,
                    optim_method,
                    est_method,
                    h,
                    maxit,
                    pop_size = NULL,
                    pop_totals = NULL,
                    ...){
  mu_hats <- vector(mode = "numeric", length = num_boot)
  if (!is.null(weights_rand)) N <- sum(weights_rand)
  estimation_method <- get_method(est_method)
  method <- get_method(method_selection)
  inv_link <- method$make_link_inv
  k <- 1

  while (k <= num_boot) {

    if (is.null(pop_totals)) {
      strap_nons <- sample.int(replace = TRUE, n = n_nons)
      strap_rand <- sample.int(replace = TRUE, n = n_rand)

      X <- rbind(X_rand[strap_rand, ],
                 X_nons[strap_nons, ])

      model_sel <- internal_selection(X = X,
                                      X_nons = X_nons[strap_nons, ],
                                      X_rand = X_rand[strap_rand, ],
                                      weights = weights[strap_nons],
                                      weights_rand = weights_rand[strap_rand],
                                      R = R,
                                      method_selection = method_selection,
                                      optim_method = optim_method,
                                      h = h,
                                      est_method =  est_method,
                                      maxit = maxit)

      est_method_obj <- estimation_method$estimation_model(model = model_sel,
                                                           method_selection = method_selection)

      ps_nons <- est_method_obj$ps_nons
      weights_nons <- 1/ps_nons
      N_est_nons <- ifelse(is.null(pop_size), sum(1/ps_nons), pop_size)

      mu_hat_boot <- mu_hatIPW(y = y[strap_nons],
                              weights = weights_nons,
                              N = N_est_nons) # IPW estimator
      mu_hats[k] <- mu_hat_boot

    } else {
      strap <- sample.int(replace = TRUE, n = n_nons)

      X_strap <- X_nons[strap, ]
      R_strap <- R[strap]
      weights_strap <- weights[strap]

      h_object_strap <- theta_h_estimation(R = R_strap,
                                           X = X_strap,
                                           weights_rand = NULL,
                                           weights = weights_strap,
                                           h = h,
                                           method_selection = method_selection,
                                           maxit = maxit,
                                           pop_totals = pop_totals)
      theta_hat_strap <- h_object_strap$theta_h
      ps_nons <- inv_link(theta_hat_strap %*% t(X_strap))

      weights_nons <- 1/ps_nons
      N_est_nons <- ifelse(is.null(pop_size), sum(weights_nons), pop_size)

      mu_hat_boot <- mu_hatIPW(y = y[strap],
                               weights = weights_nons,
                               N = N_est_nons) # IPW estimator
      mu_hats[k] <- mu_hat_boot
    }
    k <- k + 1
  }

  boot_var <- 1/num_boot * sum((mu_hats - mu_hat)^2)
  list(boot_var = boot_var)
}

bootDR <- function(SelectionModel,
                   OutcomeModel,
                   family_outcome,
                   num_boot,
                   weights,
                   weights_rand,
                   R,
                   theta_hat,
                   mu_hat,
                   method_selection,
                   n_nons,
                   n_rand,
                   optim_method,
                   est_method,
                   h,
                   maxit = NULL,
                   pop_size = NULL,
                   pop_totals = NULL,
                   ...) {

  mu_hats <- vector(mode = "numeric", length = num_boot)
  N <- sum(weights_rand)
  estimation_method <- get_method(est_method)
  k <- 1

  while (k <= num_boot) {

    if (is.null(pop_totals)) {
      strap_nons <- sample.int(replace = TRUE, n = n_nons)
      strap_rand <- sample.int(replace = TRUE, n = n_rand)

      model_out <- internal_outcome(X_nons = OutcomeModel$X_nons[strap_nons, ],
                                    X_rand = OutcomeModel$X_rand[strap_rand, ],
                                    y = OutcomeModel$y[strap_nons],
                                    weights = weights[strap_nons],
                                    family_outcome = family_outcome)

      y_rand_pred <- model_out$y_rand_pred
      y_nons_pred <- model_out$y_nons_pred
      model_nons_coefs <- model_out$model_nons_coefs

      X_sel <- rbind(SelectionModel$X_rand[strap_rand, ],
                     SelectionModel$X_nons[strap_nons, ])

      model_sel <- internal_selection(X = X_sel,
                                      X_nons = SelectionModel$X_nons[strap_nons, ],
                                      X_rand = SelectionModel$X_rand[strap_rand, ],
                                      weights = weights[strap_nons],
                                      weights_rand = weights_rand[strap_rand],
                                      R = R,
                                      method_selection = method_selection,
                                      optim_method = optim_method,
                                      h = h,
                                      est_method = est_method,
                                      maxit = maxit)

      est_method_obj <- estimation_method$estimation_model(model = model_sel,
                                                           method_selection = method_selection)
      ps_nons <- est_method_obj$ps_nons
      weights_nons <- 1/ps_nons
      N_est_nons <- sum(weights_nons)
      N_est_rand <- sum(weights_rand[strap_rand])

      mu_hat_boot <- mu_hatDR(y = OutcomeModel$y_nons[strap_nons],
                              y_nons = y_nons_pred,
                              y_rand = y_rand_pred,
                              weights_nons = weights_nons,
                              weights_rand = weights_rand[strap_rand],
                              N_nons = N_est_nons,
                              N_rand = N_est_rand)
      mu_hats[k] <- mu_hat_boot
    } else { # TODO

      strap <- sample.int(replace = TRUE, n = n_nons)
      X_strap <- X_nons[strap, ]
      y_strap <- y_nons[strap]
      R_strap <- rep(1, nrow(X_strap))
      weights_strap <- weights[strap]


      h_object_strap <- theta_h_estimation(R = R_strap,
                                           X = X_strap,
                                           weights_rand = NULL,
                                           weights = weights_strap,
                                           h = h,
                                           method_selection = method_selection,
                                           maxit = maxit,
                                           pop_totals = pop_totals)

      theta_hat_strap <- h_object$theta_h
      ethod <- get_method(method_selection)
      inv_link <- method$make_link_inv
      ps_nons_strap <- inv_link(theta_hat_strap %*% t(X_strap))
      N_est <- sum(1/ps_nons_strap)
      if(is.null(pop_size)) pop_size <- N_est

      model_out_strap <- internal_outcome(X_nons = X_strap,
                                          X_rand = c(pop_size, pop_totals), # <--- pop_size is an intercept in the model
                                          y = y_strap,
                                          weights = weights,
                                          family_outcome = family_outcome,
                                          pop_totals = TRUE)

      y_rand_pred <- model_out$y_rand_pred
      y_nons_pred <- model_out$y_nons_pred
      model_nons_coefs <- model_out$model_nons_coefs

      mu_hat_boot <- mu_hatDR(y = y_strap,
                              y_nons = y_nons_pred,
                              y_rand = y_rand_pred,
                              weights_nons = weights_nons,
                              weights_rand = weights_rand[strap_rand],
                              N_nons = N_est,
                              N_rand = N_est_rand)
      mu_hats[k] <- mu_hat_boot

    }
    k <- k + 1
  }

  boot_var <- 1/num_boot * sum((mu_hats - mu_hat)^2)
  list(boot_var = boot_var)
}
