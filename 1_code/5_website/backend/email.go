package main

import (
	"fmt"
	"net/smtp"
	"os"
	"strings"
)

// EmailConfig holds SMTP settings for sending verification emails.
// Defaults target Gmail SMTP with an app password -- see
// backend/README.md for how to generate one.
type EmailConfig struct {
	Host        string
	Port        string
	Username    string
	Password    string
	From        string
	BackendURL  string
	FrontendURL string
}

func loadEmailConfig() EmailConfig {
	username := os.Getenv("SMTP_USERNAME")
	return EmailConfig{
		Host:        getenv("SMTP_HOST", "smtp.gmail.com"),
		Port:        getenv("SMTP_PORT", "587"),
		Username:    username,
		Password:    os.Getenv("SMTP_PASSWORD"),
		From:        getenv("SMTP_FROM", username),
		BackendURL:  getenv("PUBLIC_BACKEND_URL", "http://localhost:8080"),
		FrontendURL: getenv("PUBLIC_FRONTEND_URL", "http://localhost:5173"),
	}
}

func (c EmailConfig) sendVerificationEmail(toEmail, token string) error {
	link := fmt.Sprintf("%s/api/auth/verify?token=%s", c.BackendURL, token)

	subject := "Verify your PhenoMAP account"
	body := fmt.Sprintf(
		"Welcome to PhenoMAP!\r\n\r\nClick the link below to verify your email address:\r\n%s\r\n\r\nThis link expires in 24 hours. If you didn't sign up, you can ignore this email.\r\n",
		link,
	)
	msg := fmt.Sprintf(
		"From: %s\r\nTo: %s\r\nSubject: %s\r\nMIME-Version: 1.0\r\nContent-Type: text/plain; charset=\"UTF-8\"\r\n\r\n%s",
		c.From, toEmail, subject, body,
	)

	auth := smtp.PlainAuth("", c.Username, c.Password, c.Host)
	addr := c.Host + ":" + c.Port
	return smtp.SendMail(addr, auth, c.From, []string{toEmail}, []byte(msg))
}

// contactRecipient is where messages submitted through the Contact page's
// "Send a Message" form are delivered.
const contactRecipient = "phenomap.shenlab@gmail.com"

// sendContactMessage relays a message submitted through the Contact page to
// contactRecipient, with Reply-To set to the submitter's address so a
// direct reply reaches them without exposing SMTP credentials either way.
func (c EmailConfig) sendContactMessage(name, fromEmail, message string) error {
	subject := "PhenoMAP contact form: " + name
	body := fmt.Sprintf(
		"New message from the PhenoMAP contact form.\r\n\r\nName: %s\r\nEmail: %s\r\n\r\n%s\r\n",
		name, fromEmail, message,
	)
	msg := fmt.Sprintf(
		"From: %s\r\nTo: %s\r\nReply-To: %s\r\nSubject: %s\r\nMIME-Version: 1.0\r\nContent-Type: text/plain; charset=\"UTF-8\"\r\n\r\n%s",
		c.From, contactRecipient, fromEmail, subject, body,
	)

	auth := smtp.PlainAuth("", c.Username, c.Password, c.Host)
	addr := c.Host + ":" + c.Port
	return smtp.SendMail(addr, auth, c.From, []string{contactRecipient}, []byte(msg))
}

// sendEmailChangeVerification is sent to the *new* address someone entered
// on the account page, not the account's current email -- clicking the
// link is what proves that address is real and reachable by them before
// it gets attached to the account.
func (c EmailConfig) sendEmailChangeVerification(toEmail, token string) error {
	link := fmt.Sprintf("%s/api/auth/confirm-email-change?token=%s", c.BackendURL, token)

	subject := "Confirm your new PhenoMAP email address"
	body := fmt.Sprintf(
		"We received a request to change the email address on a PhenoMAP account to this address.\r\n\r\nClick the link below to confirm the change:\r\n%s\r\n\r\nThis link expires in 24 hours. If you didn't request this, you can ignore this email -- the account's email won't change.\r\n",
		link,
	)
	msg := fmt.Sprintf(
		"From: %s\r\nTo: %s\r\nSubject: %s\r\nMIME-Version: 1.0\r\nContent-Type: text/plain; charset=\"UTF-8\"\r\n\r\n%s",
		c.From, toEmail, subject, body,
	)

	auth := smtp.PlainAuth("", c.Username, c.Password, c.Host)
	addr := c.Host + ":" + c.Port
	return smtp.SendMail(addr, auth, c.From, []string{toEmail}, []byte(msg))
}

// sendAccountDeletionConfirmation is sent to the account's current email
// address after a deletion is requested from the account page. The
// account isn't actually removed until this link is clicked, which
// proves whoever asked for the deletion also controls that inbox.
func (c EmailConfig) sendAccountDeletionConfirmation(toEmail, token string) error {
	link := fmt.Sprintf("%s/api/auth/confirm-delete-account?token=%s", c.BackendURL, token)

	subject := "Confirm deleting your PhenoMAP account"
	body := fmt.Sprintf(
		"We received a request to permanently delete this PhenoMAP account.\r\n\r\nClick the link below to confirm the deletion:\r\n%s\r\n\r\nThis link expires in 24 hours. If you didn't request this, you can ignore this email -- the account will not be deleted.\r\n",
		link,
	)
	msg := fmt.Sprintf(
		"From: %s\r\nTo: %s\r\nSubject: %s\r\nMIME-Version: 1.0\r\nContent-Type: text/plain; charset=\"UTF-8\"\r\n\r\n%s",
		c.From, toEmail, subject, body,
	)

	auth := smtp.PlainAuth("", c.Username, c.Password, c.Host)
	addr := c.Host + ":" + c.Port
	return smtp.SendMail(addr, auth, c.From, []string{toEmail}, []byte(msg))
}

// sendCommunitySubmissionNotice emails contactRecipient whenever someone
// submits study data through the Community page, so a new submission
// doesn't just sit unnoticed in the database until a curator happens to
// check -- review of the submission itself is still a manual, offline
// process (see community.go), this just makes sure someone finds out.
// Reply-To is the submitter's contact email, matching sendContactMessage.
func (c EmailConfig) sendCommunitySubmissionNotice(user *User, s *CommunitySubmission) error {
	fileNames := make([]string, 0, len(s.Files))
	for _, f := range s.Files {
		fileNames = append(fileNames, f.Name)
	}

	subject := fmt.Sprintf("PhenoMAP community submission %s: %s", s.ID, s.Title)
	body := fmt.Sprintf(
		"New study data submission for review.\r\n\r\n"+
			"Submission ID: %s\r\nSubmitted by: %s <%s>\r\n\r\n"+
			"Title: %s\r\nPhenotype: %s (%s)\r\nStudy design: %s\r\nSample size: %d\r\n"+
			"Biospecimen: %s\r\nMS2 support: %s\r\nChromatography: %s\r\nMass spectrometry: %s\r\n\r\n"+
			"Summary:\r\n%s\r\n\r\n"+
			"DOI: %s\r\nSource link: %s\r\nContact: %s <%s>\r\nReviewer notes: %s\r\n\r\n"+
			"Files: %s\r\n",
		s.ID, user.DisplayName, user.Email,
		s.Title, s.Phenotype, s.PhenotypeID, s.StudyDesign, s.SampleSize,
		s.Biospecimen, s.MS2Supported, s.Chromatography, s.MassSpectrometry,
		s.Summary,
		s.DOI, s.SourceLink, s.ContactName, s.ContactEmail, s.Notes,
		strings.Join(fileNames, ", "),
	)
	msg := fmt.Sprintf(
		"From: %s\r\nTo: %s\r\nReply-To: %s\r\nSubject: %s\r\nMIME-Version: 1.0\r\nContent-Type: text/plain; charset=\"UTF-8\"\r\n\r\n%s",
		c.From, contactRecipient, s.ContactEmail, subject, body,
	)

	auth := smtp.PlainAuth("", c.Username, c.Password, c.Host)
	addr := c.Host + ":" + c.Port
	return smtp.SendMail(addr, auth, c.From, []string{contactRecipient}, []byte(msg))
}

func (c EmailConfig) sendPasswordResetEmail(toEmail, token string) error {
	link := fmt.Sprintf("%s/reset-password?token=%s", c.FrontendURL, token)

	subject := "Reset your PhenoMAP password"
	body := fmt.Sprintf(
		"We received a request to reset your PhenoMAP password.\r\n\r\nClick the link below to choose a new password:\r\n%s\r\n\r\nThis link expires in 1 hour. If you didn't request this, you can ignore this email -- your password won't change.\r\n",
		link,
	)
	msg := fmt.Sprintf(
		"From: %s\r\nTo: %s\r\nSubject: %s\r\nMIME-Version: 1.0\r\nContent-Type: text/plain; charset=\"UTF-8\"\r\n\r\n%s",
		c.From, toEmail, subject, body,
	)

	auth := smtp.PlainAuth("", c.Username, c.Password, c.Host)
	addr := c.Host + ":" + c.Port
	return smtp.SendMail(addr, auth, c.From, []string{toEmail}, []byte(msg))
}
