package main

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"
)

const officialFreeDailyLimit = 50

type ChatQuota struct {
	Date      string `json:"date"`
	Limit     int    `json:"limit"`
	Used      int    `json:"used"`
	Remaining int    `json:"remaining"`
}

func todayUsageDate() string {
	return time.Now().In(time.FixedZone("Asia/Singapore", 8*60*60)).Format("2006-01-02")
}

func quotaPayload(date string, used int) ChatQuota {
	remaining := officialFreeDailyLimit - used
	if remaining < 0 {
		remaining = 0
	}
	return ChatQuota{
		Date:      date,
		Limit:     officialFreeDailyLimit,
		Used:      used,
		Remaining: remaining,
	}
}

func (a *AuthDB) OfficialChatQuota(ctx context.Context, sessionToken string) (ChatQuota, error) {
	user, err := a.CurrentUser(ctx, sessionToken)
	if err != nil {
		return ChatQuota{}, err
	}
	date := todayUsageDate()

	var used int
	err = a.db.QueryRowContext(
		ctx,
		`SELECT official_free_count FROM chat_daily_usage WHERE user_id = ? AND usage_date = ?`,
		user.ID,
		date,
	).Scan(&used)
	if errors.Is(err, sql.ErrNoRows) {
		return quotaPayload(date, 0), nil
	}
	if err != nil {
		return ChatQuota{}, fmt.Errorf("load chat quota: %w", err)
	}
	return quotaPayload(date, used), nil
}

func (a *AuthDB) ConsumeOfficialChatQuota(ctx context.Context, sessionToken string) (ChatQuota, bool, error) {
	user, err := a.CurrentUser(ctx, sessionToken)
	if err != nil {
		return ChatQuota{}, false, err
	}
	date := todayUsageDate()

	tx, err := a.db.BeginTx(ctx, nil)
	if err != nil {
		return ChatQuota{}, false, fmt.Errorf("begin chat quota tx: %w", err)
	}
	defer tx.Rollback()

	var used int
	err = tx.QueryRowContext(
		ctx,
		`SELECT official_free_count FROM chat_daily_usage WHERE user_id = ? AND usage_date = ?`,
		user.ID,
		date,
	).Scan(&used)
	if errors.Is(err, sql.ErrNoRows) {
		if _, err := tx.ExecContext(
			ctx,
			`INSERT INTO chat_daily_usage (user_id, usage_date, official_free_count) VALUES (?, ?, 0)`,
			user.ID,
			date,
		); err != nil {
			return ChatQuota{}, false, fmt.Errorf("create chat quota row: %w", err)
		}
		used = 0
	} else if err != nil {
		return ChatQuota{}, false, fmt.Errorf("load chat quota: %w", err)
	}

	if used >= officialFreeDailyLimit {
		if err := tx.Commit(); err != nil {
			return ChatQuota{}, false, fmt.Errorf("commit chat quota tx: %w", err)
		}
		return quotaPayload(date, used), false, nil
	}

	used++
	if _, err := tx.ExecContext(
		ctx,
		`UPDATE chat_daily_usage SET official_free_count = ? WHERE user_id = ? AND usage_date = ?`,
		used,
		user.ID,
		date,
	); err != nil {
		return ChatQuota{}, false, fmt.Errorf("update chat quota: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return ChatQuota{}, false, fmt.Errorf("commit chat quota tx: %w", err)
	}
	return quotaPayload(date, used), true, nil
}
