package main

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"regexp"
	"strings"
	"time"
)

var (
	reHasUpper   = regexp.MustCompile(`[A-Z]`)
	reHasLower   = regexp.MustCompile(`[a-z]`)
	reHasDigit   = regexp.MustCompile(`[0-9]`)
	reHasSpecial = regexp.MustCompile(`[^A-Za-z0-9]`)
)

// validatePassword requires more than 8 characters and at least 3 of the
// 4 character classes (uppercase, lowercase, digit, special character).
func validatePassword(pw string) error {
	if len(pw) <= 8 {
		return errors.New("password must be longer than 8 characters")
	}
	classes := 0
	for _, hit := range []bool{
		reHasUpper.MatchString(pw),
		reHasLower.MatchString(pw),
		reHasDigit.MatchString(pw),
		reHasSpecial.MatchString(pw),
	} {
		if hit {
			classes++
		}
	}
	if classes < 3 {
		return errors.New("password must contain at least 3 of: uppercase letter, lowercase letter, digit, special character")
	}
	return nil
}

const sessionCookieName = "phenomap_session"

func setSessionCookie(w http.ResponseWriter, token string) {
	secure := getenv("SESSION_COOKIE_SECURE", "false") == "true"
	http.SetCookie(w, &http.Cookie{
		Name:     sessionCookieName,
		Value:    token,
		Path:     "/",
		HttpOnly: true,
		Secure:   secure,
		SameSite: http.SameSiteLaxMode,
		Expires:  time.Now().Add(30 * 24 * time.Hour),
	})
}

func clearSessionCookie(w http.ResponseWriter) {
	http.SetCookie(w, &http.Cookie{
		Name:     sessionCookieName,
		Value:    "",
		Path:     "/",
		HttpOnly: true,
		MaxAge:   -1,
	})
}

func sessionTokenFromRequest(r *http.Request) string {
	c, err := r.Cookie(sessionCookieName)
	if err != nil {
		return ""
	}
	return c.Value
}

type signUpRequest struct {
	Email       string `json:"email"`
	Password    string `json:"password"`
	DisplayName string `json:"display_name"`
	Institution string `json:"institution"`
	Country     string `json:"country"`
}

// POST /api/auth/signup
func handleSignUp(authDB *AuthDB, emailCfg EmailConfig) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req signUpRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "invalid request body")
			return
		}
		req.Email = strings.ToLower(strings.TrimSpace(req.Email))
		req.DisplayName = strings.TrimSpace(req.DisplayName)
		req.Institution = strings.TrimSpace(req.Institution)
		req.Country = strings.TrimSpace(req.Country)
		if req.DisplayName == "" {
			req.DisplayName = req.Email
		}
		if req.Email == "" || !strings.Contains(req.Email, "@") {
			writeError(w, http.StatusBadRequest, "a valid email is required")
			return
		}
		if req.Institution == "" {
			writeError(w, http.StatusBadRequest, "institution is required")
			return
		}
		if req.Country == "" {
			writeError(w, http.StatusBadRequest, "country/region is required")
			return
		}
		if err := validatePassword(req.Password); err != nil {
			writeError(w, http.StatusBadRequest, err.Error())
			return
		}

		ctx, cancel := context.WithTimeout(r.Context(), 8*time.Second)
		defer cancel()

		_, token, err := authDB.SignUp(ctx, req.Email, req.Password, req.DisplayName, req.Institution, req.Country)
		if err != nil {
			if errors.Is(err, ErrEmailTaken) {
				writeError(w, http.StatusConflict, err.Error())
				return
			}
			log.Printf("signup error: %v", err)
			writeError(w, http.StatusInternalServerError, "signup failed")
			return
		}

		if err := emailCfg.sendVerificationEmail(req.Email, token); err != nil {
			log.Printf("send verification email error: %v", err)
			writeError(w, http.StatusBadGateway,
				"account created, but the verification email failed to send -- check SMTP settings in .env, then use 'resend verification email' on the sign-in page")
			return
		}

		writeJSON(w, http.StatusOK, map[string]string{
			"message": "Account created. Check your email for a verification link.",
		})
	}
}

type loginRequest struct {
	Email    string `json:"email"`
	Password string `json:"password"`
}

// POST /api/auth/login
func handleLogin(authDB *AuthDB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req loginRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "invalid request body")
			return
		}
		req.Email = strings.ToLower(strings.TrimSpace(req.Email))

		ctx, cancel := context.WithTimeout(r.Context(), 8*time.Second)
		defer cancel()

		user, token, err := authDB.Login(ctx, req.Email, req.Password)
		if err != nil {
			switch {
			case errors.Is(err, ErrEmailUnverified):
				writeError(w, http.StatusForbidden, err.Error())
			case errors.Is(err, ErrInvalidLogin):
				writeError(w, http.StatusUnauthorized, err.Error())
			default:
				log.Printf("login error: %v", err)
				writeError(w, http.StatusInternalServerError, "login failed")
			}
			return
		}

		setSessionCookie(w, token)
		writeJSON(w, http.StatusOK, user)
	}
}

// POST /api/auth/logout
func handleLogout(authDB *AuthDB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		token := sessionTokenFromRequest(r)
		if token != "" {
			ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
			defer cancel()
			_ = authDB.Logout(ctx, token)
		}
		clearSessionCookie(w)
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	}
}

type deleteAccountRequest struct {
	Password string `json:"password"`
}

// POST /api/auth/delete-account
//
// This doesn't delete the account yet -- it sends a confirmation link to
// the account's current email. The account is only removed once that
// link is clicked (handleConfirmAccountDeletion), so knowing the password
// isn't enough by itself to destroy the account.
func handleDeleteAccount(authDB *AuthDB, emailCfg EmailConfig) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req deleteAccountRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "invalid request body")
			return
		}
		if strings.TrimSpace(req.Password) == "" {
			writeError(w, http.StatusBadRequest, "password is required")
			return
		}

		token := sessionTokenFromRequest(r)
		ctx, cancel := context.WithTimeout(r.Context(), 8*time.Second)
		defer cancel()

		user, deleteToken, err := authDB.RequestAccountDeletion(ctx, token, req.Password)
		if err != nil {
			switch {
			case errors.Is(err, ErrInvalidLogin):
				writeError(w, http.StatusUnauthorized, ErrInvalidLogin.Error())
			case errors.Is(err, ErrNotFound):
				writeError(w, http.StatusUnauthorized, "not signed in")
			default:
				log.Printf("request account deletion error: %v", err)
				writeError(w, http.StatusInternalServerError, "account deletion failed")
			}
			return
		}

		if err := emailCfg.sendAccountDeletionConfirmation(user.Email, deleteToken); err != nil {
			log.Printf("send account deletion confirmation error: %v", err)
			writeError(w, http.StatusBadGateway, "couldn't send the confirmation email -- please try again shortly")
			return
		}

		writeJSON(w, http.StatusOK, map[string]string{
			"message": "Check your email for a link to confirm account deletion.",
		})
	}
}

// GET /api/auth/confirm-delete-account?token=...
func handleConfirmAccountDeletion(authDB *AuthDB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		token := r.URL.Query().Get("token")
		frontendURL := getenv("PUBLIC_FRONTEND_URL", "http://localhost:5173")

		ctx, cancel := context.WithTimeout(r.Context(), 8*time.Second)
		defer cancel()

		if err := authDB.ConfirmAccountDeletion(ctx, token); err != nil {
			http.Redirect(w, r, frontendURL+"/login?account_deleted=0", http.StatusFound)
			return
		}

		clearSessionCookie(w)
		http.Redirect(w, r, frontendURL+"/login?account_deleted=1", http.StatusFound)
	}
}

type updateProfileRequest struct {
	DisplayName string `json:"display_name"`
	Institution string `json:"institution"`
	Country     string `json:"country"`
}

// POST /api/auth/update-profile
func handleUpdateProfile(authDB *AuthDB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req updateProfileRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "invalid request body")
			return
		}
		req.DisplayName = strings.TrimSpace(req.DisplayName)
		req.Institution = strings.TrimSpace(req.Institution)
		req.Country = strings.TrimSpace(req.Country)
		if req.DisplayName == "" {
			writeError(w, http.StatusBadRequest, "display name is required")
			return
		}
		if req.Institution == "" {
			writeError(w, http.StatusBadRequest, "institution is required")
			return
		}
		if req.Country == "" {
			writeError(w, http.StatusBadRequest, "country/region is required")
			return
		}

		token := sessionTokenFromRequest(r)
		ctx, cancel := context.WithTimeout(r.Context(), 8*time.Second)
		defer cancel()

		user, err := authDB.UpdateProfile(ctx, token, req.DisplayName, req.Institution, req.Country)
		if err != nil {
			if errors.Is(err, ErrNotFound) {
				writeError(w, http.StatusUnauthorized, "not signed in")
				return
			}
			log.Printf("update profile error: %v", err)
			writeError(w, http.StatusInternalServerError, "profile update failed")
			return
		}
		writeJSON(w, http.StatusOK, user)
	}
}

type updateEmailRequest struct {
	NewEmail string `json:"new_email"`
	Password string `json:"password"`
}

// POST /api/auth/update-email
//
// This doesn't change the account's email yet -- it only sends a
// confirmation link to the *new* address. The change only takes effect
// once that link is clicked (handleConfirmEmailChange), which proves the
// new address is real and belongs to whoever is asking for the change.
func handleUpdateEmail(authDB *AuthDB, emailCfg EmailConfig) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req updateEmailRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "invalid request body")
			return
		}
		req.NewEmail = strings.ToLower(strings.TrimSpace(req.NewEmail))
		if req.NewEmail == "" || !strings.Contains(req.NewEmail, "@") {
			writeError(w, http.StatusBadRequest, "a valid email is required")
			return
		}
		if strings.TrimSpace(req.Password) == "" {
			writeError(w, http.StatusBadRequest, "password is required")
			return
		}

		token := sessionTokenFromRequest(r)
		ctx, cancel := context.WithTimeout(r.Context(), 8*time.Second)
		defer cancel()

		changeToken, err := authDB.RequestEmailChange(ctx, token, req.NewEmail, req.Password)
		if err != nil {
			switch {
			case errors.Is(err, ErrNotFound):
				writeError(w, http.StatusUnauthorized, "not signed in")
			case errors.Is(err, ErrInvalidLogin):
				writeError(w, http.StatusUnauthorized, "incorrect password")
			case errors.Is(err, ErrEmailTaken):
				writeError(w, http.StatusConflict, err.Error())
			case errors.Is(err, ErrEmailUnchanged):
				writeError(w, http.StatusBadRequest, err.Error())
			default:
				log.Printf("request email change error: %v", err)
				writeError(w, http.StatusInternalServerError, "email update failed")
			}
			return
		}

		if err := emailCfg.sendEmailChangeVerification(req.NewEmail, changeToken); err != nil {
			log.Printf("send email change verification error: %v", err)
			writeError(w, http.StatusBadGateway, "couldn't send the confirmation email -- please try again shortly")
			return
		}

		writeJSON(w, http.StatusOK, map[string]string{
			"message": "Check your new email address for a link to confirm the change.",
		})
	}
}

// GET /api/auth/confirm-email-change?token=...
func handleConfirmEmailChange(authDB *AuthDB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		token := r.URL.Query().Get("token")
		frontendURL := getenv("PUBLIC_FRONTEND_URL", "http://localhost:5173")

		ctx, cancel := context.WithTimeout(r.Context(), 8*time.Second)
		defer cancel()

		if err := authDB.ConfirmEmailChange(ctx, token); err != nil {
			http.Redirect(w, r, frontendURL+"/account?email_changed=0", http.StatusFound)
			return
		}
		http.Redirect(w, r, frontendURL+"/account?email_changed=1", http.StatusFound)
	}
}

type changePasswordRequest struct {
	CurrentPassword string `json:"current_password"`
	NewPassword     string `json:"new_password"`
}

// POST /api/auth/change-password
func handleChangePassword(authDB *AuthDB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req changePasswordRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "invalid request body")
			return
		}
		if strings.TrimSpace(req.CurrentPassword) == "" {
			writeError(w, http.StatusBadRequest, "current password is required")
			return
		}
		if err := validatePassword(req.NewPassword); err != nil {
			writeError(w, http.StatusBadRequest, err.Error())
			return
		}

		token := sessionTokenFromRequest(r)
		ctx, cancel := context.WithTimeout(r.Context(), 8*time.Second)
		defer cancel()

		if err := authDB.ChangePassword(ctx, token, req.CurrentPassword, req.NewPassword); err != nil {
			switch {
			case errors.Is(err, ErrNotFound):
				writeError(w, http.StatusUnauthorized, "not signed in")
			case errors.Is(err, ErrInvalidLogin):
				writeError(w, http.StatusUnauthorized, "current password is incorrect")
			default:
				log.Printf("change password error: %v", err)
				writeError(w, http.StatusInternalServerError, "password change failed")
			}
			return
		}
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	}
}

// GET /api/auth/me
func handleMe(authDB *AuthDB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		token := sessionTokenFromRequest(r)
		ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
		defer cancel()

		user, err := authDB.CurrentUser(ctx, token)
		if err != nil {
			writeError(w, http.StatusUnauthorized, "not signed in")
			return
		}
		writeJSON(w, http.StatusOK, user)
	}
}

// GET /api/auth/verify?token=...
func handleVerifyEmail(authDB *AuthDB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		token := r.URL.Query().Get("token")
		frontendURL := getenv("PUBLIC_FRONTEND_URL", "http://localhost:5173")

		ctx, cancel := context.WithTimeout(r.Context(), 8*time.Second)
		defer cancel()

		if err := authDB.VerifyEmail(ctx, token); err != nil {
			http.Redirect(w, r, frontendURL+"/login?verified=0", http.StatusFound)
			return
		}
		http.Redirect(w, r, frontendURL+"/login?verified=1", http.StatusFound)
	}
}

type resendRequest struct {
	Email string `json:"email"`
}

// POST /api/auth/resend-verification
func handleResendVerification(authDB *AuthDB, emailCfg EmailConfig) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req resendRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "invalid request body")
			return
		}
		req.Email = strings.ToLower(strings.TrimSpace(req.Email))

		ctx, cancel := context.WithTimeout(r.Context(), 8*time.Second)
		defer cancel()

		user, token, err := authDB.ResendVerification(ctx, req.Email)
		if err == nil {
			if sendErr := emailCfg.sendVerificationEmail(user.Email, token); sendErr != nil {
				log.Printf("resend verification email error: %v", sendErr)
			}
		}
		// Always the same generic message, whether or not the email
		// exists / is already verified, so this can't be used to probe
		// which emails are registered.
		writeJSON(w, http.StatusOK, map[string]string{
			"message": "If that email exists and isn't verified yet, a new verification email has been sent.",
		})
	}
}

type forgotPasswordRequest struct {
	Email string `json:"email"`
}

// POST /api/auth/forgot-password
func handleForgotPassword(authDB *AuthDB, emailCfg EmailConfig) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req forgotPasswordRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "invalid request body")
			return
		}
		req.Email = strings.ToLower(strings.TrimSpace(req.Email))

		ctx, cancel := context.WithTimeout(r.Context(), 8*time.Second)
		defer cancel()

		user, token, err := authDB.RequestPasswordReset(ctx, req.Email)
		if err == nil {
			if sendErr := emailCfg.sendPasswordResetEmail(user.Email, token); sendErr != nil {
				log.Printf("send password reset email error: %v", sendErr)
			}
		}
		// Same generic message either way, so this can't be used to probe
		// which emails are registered.
		writeJSON(w, http.StatusOK, map[string]string{
			"message": "If that email has an account, a password reset link has been sent.",
		})
	}
}

type resetPasswordRequest struct {
	Token    string `json:"token"`
	Password string `json:"password"`
}

// POST /api/auth/reset-password
func handleResetPassword(authDB *AuthDB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req resetPasswordRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "invalid request body")
			return
		}
		req.Token = strings.TrimSpace(req.Token)
		if req.Token == "" {
			writeError(w, http.StatusBadRequest, "missing token")
			return
		}
		if err := validatePassword(req.Password); err != nil {
			writeError(w, http.StatusBadRequest, err.Error())
			return
		}

		ctx, cancel := context.WithTimeout(r.Context(), 8*time.Second)
		defer cancel()

		if err := authDB.ResetPassword(ctx, req.Token, req.Password); err != nil {
			if errors.Is(err, ErrNotFound) {
				writeError(w, http.StatusBadRequest, "that reset link is invalid or expired")
				return
			}
			log.Printf("reset password error: %v", err)
			writeError(w, http.StatusInternalServerError, "reset failed")
			return
		}

		writeJSON(w, http.StatusOK, map[string]string{
			"message": "Password updated. You can sign in with your new password now.",
		})
	}
}
