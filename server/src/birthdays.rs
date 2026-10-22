//! Birthdays (F19): an optional month and day on your profile, with the year
//! if you want. Friends-only like the rest of the profile, and not end-to-end
//! encrypted (like display names). Friends' chat lists get the month and day
//! so they can show a 🎂 on the day; the year only shows on the profile.

use axum::{extract::State, Json};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sqlx::{FromRow, SqlitePool};

use crate::{
    auth::AuthUser,
    db::now,
    error::{AppError, AppResult},
    SharedState,
};

#[derive(Debug, Clone, PartialEq, Serialize, FromRow)]
pub struct Birthday {
    pub month: i64,
    pub day: i64,
    pub year: Option<i64>,
}

/// For `list_chats`: `u`'s birthday as "MM-DD", or NULL.
pub const BIRTHDAY_MD: &str = "(SELECT CASE WHEN b.month IS NULL THEN NULL
       ELSE printf('%02d-%02d', b.month, b.day) END
     FROM user_birthdays b WHERE b.user_id = u.id ORDER BY b.id DESC LIMIT 1)";

fn leap(year: i64) -> bool {
    (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
}

/// A real date: February 29 is fine without a year (or in a leap year).
pub fn check(month: i64, day: i64, year: Option<i64>, this_year: i64) -> Result<(), &'static str> {
    if !(1..=12).contains(&month) {
        return Err("Pick a month.");
    }
    let days = match month {
        2 => {
            if year.is_none_or(leap) {
                29
            } else {
                28
            }
        }
        4 | 6 | 9 | 11 => 30,
        _ => 31,
    };
    if !(1..=days).contains(&day) {
        return Err("That day isn't in that month.");
    }
    if let Some(y) = year {
        if !(1900..=this_year).contains(&y) {
            return Err("That year doesn't look right. Leave it empty if you'd rather not say.");
        }
    }
    Ok(())
}

pub async fn current(db: &SqlitePool, user: i64) -> sqlx::Result<Option<Birthday>> {
    let row: Option<(Option<i64>, Option<i64>, Option<i64>)> = sqlx::query_as(
        "SELECT month, day, year FROM user_birthdays WHERE user_id = ? ORDER BY id DESC LIMIT 1",
    )
    .bind(user)
    .fetch_optional(db)
    .await?;
    Ok(match row {
        Some((Some(month), Some(day), year)) => Some(Birthday { month, day, year }),
        _ => None,
    })
}

async fn record(db: &SqlitePool, user: i64, b: Option<&Birthday>) -> sqlx::Result<()> {
    sqlx::query(
        "INSERT INTO user_birthdays (user_id, month, day, year, created_at) VALUES (?, ?, ?, ?, ?)",
    )
    .bind(user)
    .bind(b.map(|b| b.month))
    .bind(b.map(|b| b.day))
    .bind(b.and_then(|b| b.year))
    .bind(now())
    .execute(db)
    .await?;
    Ok(())
}

#[derive(Deserialize)]
pub struct SetBirthday {
    month: Option<i64>,
    day: Option<i64>,
    year: Option<i64>,
}

/// `PUT /api/me/birthday` `{month, day, year?}`. No month clears it.
pub async fn set(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    Json(req): Json<SetBirthday>,
) -> AppResult<Json<Value>> {
    let birthday = match (req.month, req.day) {
        (None, _) => None,
        (Some(month), Some(day)) => {
            let this_year = time_year(now());
            check(month, day, req.year, this_year).map_err(AppError::bad)?;
            Some(Birthday {
                month,
                day,
                year: req.year,
            })
        }
        (Some(_), None) => return Err(AppError::bad("Pick a day.")),
    };
    record(&state.db, me.id, birthday.as_ref()).await?;
    tracing::info!(
        user_id = me.id,
        cleared = birthday.is_none(),
        "birthday set"
    );
    // Friends' lists and profiles show it (or stop showing it).
    crate::people::tell_friends(&state, me.id).await?;
    Ok(Json(json!({ "birthday": birthday })))
}

/// The UTC calendar year of a unix time (days to civil date, Howard Hinnant).
fn time_year(unix: i64) -> i64 {
    let z = unix.div_euclid(86_400) + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    yoe + era * 400 + i64::from(month <= 2)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::tests::temp_db;

    #[test]
    fn only_real_dates() {
        assert!(check(3, 3, None, 2026).is_ok());
        assert!(check(2, 29, None, 2026).is_ok(), "Feb 29 without a year");
        assert!(check(2, 29, Some(2000), 2026).is_ok(), "a leap year");
        assert!(check(2, 29, Some(2023), 2026).is_err());
        assert!(
            check(2, 29, Some(1900), 2026).is_err(),
            "1900 wasn't a leap year"
        );
        assert!(check(4, 31, None, 2026).is_err());
        assert!(check(12, 31, Some(1990), 2026).is_ok());
        for (m, d, y) in [
            (0, 1, None),
            (13, 1, None),
            (1, 0, None),
            (1, 32, None),
            (5, 5, Some(1899)),
            (5, 5, Some(2027)),
        ] {
            assert!(check(m, d, y, 2026).is_err(), "{m}/{d}/{y:?}");
        }
    }

    #[test]
    fn year_of_a_timestamp() {
        assert_eq!(time_year(0), 1970);
        assert_eq!(time_year(1_792_627_200), 2026); // 2026-10-22
        assert_eq!(time_year(1_767_225_599), 2025); // 2025-12-31 23:59:59
        assert_eq!(time_year(1_767_225_600), 2026); // 2026-01-01
    }

    #[tokio::test]
    async fn the_newest_row_wins_and_clearing_keeps_history() {
        let db = temp_db().await;
        sqlx::query("INSERT INTO users (id, username, auth_hash, public_key, wrapped_private_key, created_at) VALUES (1, 'ana', 'h', 'k', 'w', 0)")
            .execute(&db).await.unwrap();
        assert_eq!(current(&db, 1).await.unwrap(), None);
        let b = Birthday {
            month: 3,
            day: 3,
            year: None,
        };
        record(&db, 1, Some(&b)).await.unwrap();
        assert_eq!(current(&db, 1).await.unwrap(), Some(b));
        record(&db, 1, None).await.unwrap();
        assert_eq!(current(&db, 1).await.unwrap(), None);
        let rows: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM user_birthdays")
            .fetch_one(&db)
            .await
            .unwrap();
        assert_eq!(rows, 2, "clearing adds a row; nothing is deleted");
    }
}
