package main

import (
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"time"

	"golang.org/x/crypto/bcrypt"
)

type User struct {
	ID            string `json:"id"`
	Email         string `json:"email"`
	DisplayName   string `json:"display_name"`
	Institution   string `json:"institution"`
	Country       string `json:"country"`
	Role          string `json:"role"`
	EmailVerified bool   `json:"email_verified"`
	CreatedAt     string `json:"created_at"`
}

var (
	ErrEmailTaken      = errors.New("an account with this email already exists")
	ErrInvalidLogin    = errors.New("invalid email or password")
	ErrEmailUnverified = errors.New("please verify your email before signing in")
	ErrNotFound        = errors.New("not found")
	ErrEmailUnchanged  = errors.New("that's already your email address")
)

func randomToken(nBytes int) (string, error) {
	b := make([]byte, nBytes)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

// SignUp creates a new, unverified user and an email verification token.
// The caller is responsible for emailing the token to the user.
func (a *AuthDB) SignUp(ctx context.Context, email, password, displayName, institution, country string) (*User, string, error) {
	var exists int
	if err := a.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM users WHERE email = ?`, email).Scan(&exists); err != nil {
		return nil, "", fmt.Errorf("check existing email: %w", err)
	}
	if exists > 0 {
		return nil, "", ErrEmailTaken
	}

	hash, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
	if err != nil {
		return nil, "", fmt.Errorf("hash password: %w", err)
	}

	id, err := randomToken(16)
	if err != nil {
		return nil, "", err
	}

	if _, err := a.db.ExecContext(ctx,
		`INSERT INTO users (id, email, password_hash, display_name, institution, country) VALUES (?, ?, ?, ?, ?, ?)`,
		id, email, string(hash), displayName, institution, country,
	); err != nil {
		return nil, "", fmt.Errorf("insert user: %w", err)
	}

	verifyToken, err := a.createVerificationToken(ctx, id)
	if err != nil {
		return nil, "", err
	}

	return &User{ID: id, Email: email, DisplayName: displayName, Institution: institution, Country: country, Role: "user", EmailVerified: false}, verifyToken, nil
}

func (a *AuthDB) createVerificationToken(ctx context.Context, userID string) (string, error) {
	token, err := randomToken(32)
	if err != nil {
		return "", err
	}
	expires := time.Now().Add(24 * time.Hour).UTC().Format(time.RFC3339)
	if _, err := a.db.ExecContext(ctx,
		`INSERT INTO email_verifications (token, user_id, expires_at) VALUES (?, ?, ?)`,
		token, userID, expires,
	); err != nil {
		return "", fmt.Errorf("insert verification token: %w", err)
	}
	return token, nil
}

// VerifyEmail marks the user tied to token as verified, if the token
// exists and hasn't expired.
func (a *AuthDB) VerifyEmail(ctx context.Context, token string) error {
	var userID, expiresAt string
	err := a.db.QueryRowContext(ctx,
		`SELECT user_id, expires_at FROM email_verifications WHERE token = ?`, token,
	).Scan(&userID, &expiresAt)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrNotFound
	}
	if err != nil {
		return fmt.Errorf("look up verification token: %w", err)
	}

	expires, err := time.Parse(time.RFC3339, expiresAt)
	if err != nil || time.Now().UTC().After(expires) {
		return ErrNotFound
	}

	if _, err := a.db.ExecContext(ctx, `UPDATE users SET email_verified = 1 WHERE id = ?`, userID); err != nil {
		return fmt.Errorf("mark verified: %w", err)
	}
	if _, err := a.db.ExecContext(ctx, `DELETE FROM email_verifications WHERE token = ?`, token); err != nil {
		return fmt.Errorf("delete verification token: %w", err)
	}
	return nil
}

// ResendVerification issues a fresh verification token for an unverified
// account. Returns ErrNotFound if the email doesn't exist or is already
// verified, so callers can give a deliberately generic response and not
// leak which emails are registered.
func (a *AuthDB) ResendVerification(ctx context.Context, email string) (*User, string, error) {
	user, err := a.findByEmail(ctx, email)
	if err != nil {
		return nil, "", err
	}
	if user.EmailVerified {
		return nil, "", ErrNotFound
	}
	token, err := a.createVerificationToken(ctx, user.ID)
	if err != nil {
		return nil, "", err
	}
	return user, token, nil
}

func (a *AuthDB) findByEmail(ctx context.Context, email string) (*User, error) {
	var u User
	var verified int
	err := a.db.QueryRowContext(ctx,
		`SELECT id, email, display_name, institution, country, role, email_verified, created_at FROM users WHERE email = ?`, email,
	).Scan(&u.ID, &u.Email, &u.DisplayName, &u.Institution, &u.Country, &u.Role, &verified, &u.CreatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("find user by email: %w", err)
	}
	u.EmailVerified = verified == 1
	return &u, nil
}

// Login checks the password and, if it matches and the email is
// verified, creates a new session.
func (a *AuthDB) Login(ctx context.Context, email, password string) (*User, string, error) {
	var u User
	var passwordHash string
	var verified int
	err := a.db.QueryRowContext(ctx,
		`SELECT id, email, display_name, institution, country, role, password_hash, email_verified, created_at FROM users WHERE email = ?`, email,
	).Scan(&u.ID, &u.Email, &u.DisplayName, &u.Institution, &u.Country, &u.Role, &passwordHash, &verified, &u.CreatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, "", ErrInvalidLogin
	}
	if err != nil {
		return nil, "", fmt.Errorf("find user by email: %w", err)
	}
	u.EmailVerified = verified == 1

	if bcrypt.CompareHashAndPassword([]byte(passwordHash), []byte(password)) != nil {
		return nil, "", ErrInvalidLogin
	}
	if !u.EmailVerified {
		return nil, "", ErrEmailUnverified
	}

	token, err := a.createSession(ctx, u.ID)
	if err != nil {
		return nil, "", err
	}
	return &u, token, nil
}

func (a *AuthDB) createSession(ctx context.Context, userID string) (string, error) {
	token, err := randomToken(32)
	if err != nil {
		return "", err
	}
	expires := time.Now().Add(30 * 24 * time.Hour).UTC().Format(time.RFC3339)
	if _, err := a.db.ExecContext(ctx,
		`INSERT INTO sessions (token, user_id, expires_at) VALUES (?, ?, ?)`,
		token, userID, expires,
	); err != nil {
		return "", fmt.Errorf("insert session: %w", err)
	}
	return token, nil
}

// CurrentUser resolves a session cookie value to the logged-in user.
func (a *AuthDB) CurrentUser(ctx context.Context, sessionToken string) (*User, error) {
	if sessionToken == "" {
		return nil, ErrNotFound
	}
	var u User
	var verified int
	var expiresAt string
	err := a.db.QueryRowContext(ctx, `
		SELECT u.id, u.email, u.display_name, u.institution, u.country, u.role, u.email_verified, u.created_at, s.expires_at
		FROM sessions s
		JOIN users u ON u.id = s.user_id
		WHERE s.token = ?
	`, sessionToken).Scan(&u.ID, &u.Email, &u.DisplayName, &u.Institution, &u.Country, &u.Role, &verified, &u.CreatedAt, &expiresAt)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("look up session: %w", err)
	}

	expires, err := time.Parse(time.RFC3339, expiresAt)
	if err != nil || time.Now().UTC().After(expires) {
		_, _ = a.db.ExecContext(ctx, `DELETE FROM sessions WHERE token = ?`, sessionToken)
		return nil, ErrNotFound
	}

	u.EmailVerified = verified == 1
	return &u, nil
}

func (a *AuthDB) Logout(ctx context.Context, sessionToken string) error {
	_, err := a.db.ExecContext(ctx, `DELETE FROM sessions WHERE token = ?`, sessionToken)
	return err
}

// RequestAccountDeletion confirms the active user's password and issues a
// pending deletion token, emailed to the account's current address. The
// account isn't removed until that email's confirmation link is clicked
// (ConfirmAccountDeletion) -- so a stolen session cookie plus a guessed or
// leaked password still can't destroy the account without also
// controlling that inbox.
func (a *AuthDB) RequestAccountDeletion(ctx context.Context, sessionToken, password string) (*User, string, error) {
	user, err := a.CurrentUser(ctx, sessionToken)
	if err != nil {
		return nil, "", err
	}

	var passwordHash string
	if err := a.db.QueryRowContext(ctx, `SELECT password_hash FROM users WHERE id = ?`, user.ID).Scan(&passwordHash); err != nil {
		return nil, "", fmt.Errorf("look up password hash: %w", err)
	}
	if bcrypt.CompareHashAndPassword([]byte(passwordHash), []byte(password)) != nil {
		return nil, "", ErrInvalidLogin
	}

	// Drop any earlier pending deletion for this account so old links
	// stop working once a new one is requested.
	if _, err := a.db.ExecContext(ctx, `DELETE FROM account_deletions WHERE user_id = ?`, user.ID); err != nil {
		return nil, "", fmt.Errorf("clear old deletion requests: %w", err)
	}

	token, err := randomToken(32)
	if err != nil {
		return nil, "", err
	}
	expires := time.Now().Add(24 * time.Hour).UTC().Format(time.RFC3339)
	if _, err := a.db.ExecContext(ctx,
		`INSERT INTO account_deletions (token, user_id, expires_at) VALUES (?, ?, ?)`,
		token, user.ID, expires,
	); err != nil {
		return nil, "", fmt.Errorf("insert account deletion token: %w", err)
	}
	return user, token, nil
}

// ConfirmAccountDeletion permanently removes the account tied to token
// and all auth records that reference it, if the token exists and
// hasn't expired.
func (a *AuthDB) ConfirmAccountDeletion(ctx context.Context, token string) error {
	var userID, expiresAt string
	err := a.db.QueryRowContext(ctx,
		`SELECT user_id, expires_at FROM account_deletions WHERE token = ?`, token,
	).Scan(&userID, &expiresAt)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrNotFound
	}
	if err != nil {
		return fmt.Errorf("look up account deletion token: %w", err)
	}

	expires, err := time.Parse(time.RFC3339, expiresAt)
	if err != nil || time.Now().UTC().After(expires) {
		return ErrNotFound
	}

	tx, err := a.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("begin account deletion: %w", err)
	}
	defer tx.Rollback()

	for _, stmt := range []string{
		`DELETE FROM sessions WHERE user_id = ?`,
		`DELETE FROM email_verifications WHERE user_id = ?`,
		`DELETE FROM password_resets WHERE user_id = ?`,
		`DELETE FROM email_changes WHERE user_id = ?`,
		`DELETE FROM account_deletions WHERE user_id = ?`,
		`DELETE FROM users WHERE id = ?`,
	} {
		if _, err := tx.ExecContext(ctx, stmt, userID); err != nil {
			return fmt.Errorf("delete account records: %w", err)
		}
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("commit account deletion: %w", err)
	}
	return nil
}

// UpdateProfile changes the display name, institution, and country for the
// currently signed-in user.
func (a *AuthDB) UpdateProfile(ctx context.Context, sessionToken, displayName, institution, country string) (*User, error) {
	user, err := a.CurrentUser(ctx, sessionToken)
	if err != nil {
		return nil, err
	}
	if _, err := a.db.ExecContext(ctx,
		`UPDATE users SET display_name = ?, institution = ?, country = ? WHERE id = ?`,
		displayName, institution, country, user.ID,
	); err != nil {
		return nil, fmt.Errorf("update profile: %w", err)
	}
	user.DisplayName = displayName
	user.Institution = institution
	user.Country = country
	return user, nil
}

// RequestEmailChange confirms the caller's current password and that the
// requested new email isn't already taken, then issues a pending
// email-change token. The account's email isn't updated yet -- that only
// happens once the new address is confirmed via ConfirmEmailChange, so we
// never attach an email nobody can actually receive mail at.
func (a *AuthDB) RequestEmailChange(ctx context.Context, sessionToken, newEmail, password string) (string, error) {
	user, err := a.CurrentUser(ctx, sessionToken)
	if err != nil {
		return "", err
	}

	var passwordHash string
	if err := a.db.QueryRowContext(ctx, `SELECT password_hash FROM users WHERE id = ?`, user.ID).Scan(&passwordHash); err != nil {
		return "", fmt.Errorf("look up password hash: %w", err)
	}
	if bcrypt.CompareHashAndPassword([]byte(passwordHash), []byte(password)) != nil {
		return "", ErrInvalidLogin
	}

	if newEmail == user.Email {
		return "", ErrEmailUnchanged
	}

	var exists int
	if err := a.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM users WHERE email = ? AND id != ?`, newEmail, user.ID).Scan(&exists); err != nil {
		return "", fmt.Errorf("check existing email: %w", err)
	}
	if exists > 0 {
		return "", ErrEmailTaken
	}

	// Drop any earlier pending change for this account so old links stop
	// working once a new one is requested.
	if _, err := a.db.ExecContext(ctx, `DELETE FROM email_changes WHERE user_id = ?`, user.ID); err != nil {
		return "", fmt.Errorf("clear old email change requests: %w", err)
	}

	token, err := randomToken(32)
	if err != nil {
		return "", err
	}
	expires := time.Now().Add(24 * time.Hour).UTC().Format(time.RFC3339)
	if _, err := a.db.ExecContext(ctx,
		`INSERT INTO email_changes (token, user_id, new_email, expires_at) VALUES (?, ?, ?, ?)`,
		token, user.ID, newEmail, expires,
	); err != nil {
		return "", fmt.Errorf("insert email change token: %w", err)
	}
	return token, nil
}

// ConfirmEmailChange finalizes a pending email change if the token exists
// and hasn't expired, proving the account owner can actually receive mail
// at the new address before it's attached to the account.
func (a *AuthDB) ConfirmEmailChange(ctx context.Context, token string) error {
	var userID, newEmail, expiresAt string
	err := a.db.QueryRowContext(ctx,
		`SELECT user_id, new_email, expires_at FROM email_changes WHERE token = ?`, token,
	).Scan(&userID, &newEmail, &expiresAt)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrNotFound
	}
	if err != nil {
		return fmt.Errorf("look up email change token: %w", err)
	}

	expires, err := time.Parse(time.RFC3339, expiresAt)
	if err != nil || time.Now().UTC().After(expires) {
		return ErrNotFound
	}

	// Someone else could have claimed the address in the meantime -- check
	// again right before committing the change.
	var exists int
	if err := a.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM users WHERE email = ? AND id != ?`, newEmail, userID).Scan(&exists); err != nil {
		return fmt.Errorf("check existing email: %w", err)
	}
	if exists > 0 {
		return ErrEmailTaken
	}

	if _, err := a.db.ExecContext(ctx, `UPDATE users SET email = ? WHERE id = ?`, newEmail, userID); err != nil {
		return fmt.Errorf("update email: %w", err)
	}
	if _, err := a.db.ExecContext(ctx, `DELETE FROM email_changes WHERE user_id = ?`, userID); err != nil {
		return fmt.Errorf("delete email change token: %w", err)
	}
	return nil
}

// ChangePassword updates the password for the currently signed-in user
// after confirming their current password. Every other active session
// for the account is invalidated -- but not the one making this
// request, so the user isn't logged out of the device they're using.
func (a *AuthDB) ChangePassword(ctx context.Context, sessionToken, currentPassword, newPassword string) error {
	user, err := a.CurrentUser(ctx, sessionToken)
	if err != nil {
		return err
	}

	var passwordHash string
	if err := a.db.QueryRowContext(ctx, `SELECT password_hash FROM users WHERE id = ?`, user.ID).Scan(&passwordHash); err != nil {
		return fmt.Errorf("look up password hash: %w", err)
	}
	if bcrypt.CompareHashAndPassword([]byte(passwordHash), []byte(currentPassword)) != nil {
		return ErrInvalidLogin
	}

	hash, err := bcrypt.GenerateFromPassword([]byte(newPassword), bcrypt.DefaultCost)
	if err != nil {
		return fmt.Errorf("hash password: %w", err)
	}
	if _, err := a.db.ExecContext(ctx, `UPDATE users SET password_hash = ? WHERE id = ?`, string(hash), user.ID); err != nil {
		return fmt.Errorf("update password: %w", err)
	}
	if _, err := a.db.ExecContext(ctx, `DELETE FROM sessions WHERE user_id = ? AND token != ?`, user.ID, sessionToken); err != nil {
		return fmt.Errorf("invalidate other sessions: %w", err)
	}
	return nil
}

// RequestPasswordReset issues a password-reset token for an existing
// account. Returns ErrNotFound if the email isn't registered, so the
// caller can give a deliberately generic response and not leak which
// emails exist.
func (a *AuthDB) RequestPasswordReset(ctx context.Context, email string) (*User, string, error) {
	user, err := a.findByEmail(ctx, email)
	if err != nil {
		return nil, "", err
	}
	token, err := randomToken(32)
	if err != nil {
		return nil, "", err
	}
	expires := time.Now().Add(1 * time.Hour).UTC().Format(time.RFC3339)
	if _, err := a.db.ExecContext(ctx,
		`INSERT INTO password_resets (token, user_id, expires_at) VALUES (?, ?, ?)`,
		token, user.ID, expires,
	); err != nil {
		return nil, "", fmt.Errorf("insert password reset token: %w", err)
	}
	return user, token, nil
}

// ResetPassword sets a new password for the account tied to token, if the
// token exists and hasn't expired. All of the account's existing sessions
// are invalidated so a stolen session can't survive a password reset.
func (a *AuthDB) ResetPassword(ctx context.Context, token, newPassword string) error {
	var userID, expiresAt string
	err := a.db.QueryRowContext(ctx,
		`SELECT user_id, expires_at FROM password_resets WHERE token = ?`, token,
	).Scan(&userID, &expiresAt)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrNotFound
	}
	if err != nil {
		return fmt.Errorf("look up password reset token: %w", err)
	}

	expires, err := time.Parse(time.RFC3339, expiresAt)
	if err != nil || time.Now().UTC().After(expires) {
		return ErrNotFound
	}

	hash, err := bcrypt.GenerateFromPassword([]byte(newPassword), bcrypt.DefaultCost)
	if err != nil {
		return fmt.Errorf("hash password: %w", err)
	}
	if _, err := a.db.ExecContext(ctx, `UPDATE users SET password_hash = ? WHERE id = ?`, string(hash), userID); err != nil {
		return fmt.Errorf("update password: %w", err)
	}
	if _, err := a.db.ExecContext(ctx, `DELETE FROM password_resets WHERE token = ?`, token); err != nil {
		return fmt.Errorf("delete password reset token: %w", err)
	}
	if _, err := a.db.ExecContext(ctx, `DELETE FROM sessions WHERE user_id = ?`, userID); err != nil {
		return fmt.Errorf("invalidate sessions: %w", err)
	}
	return nil
}
