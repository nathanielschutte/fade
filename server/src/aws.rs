//! The few AWS calls the server makes, all for the admin panel's Metrics tab:
//! which instance this is (instance metadata), its CPU credits (CloudWatch),
//! and what the app has cost (Cost Explorer). Requests are signed here with
//! Signature Version 4 rather than pulling in the AWS SDK.
//!
//! Every address is fixed in this file; nothing from a request ever chooses
//! where these calls go. Credentials come from the instance role, live only in
//! memory, and are never logged (`Creds` has no Debug output).

use std::sync::Mutex;

use hmac::{Hmac, Mac};
use serde::Serialize;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

const IMDS: &str = "http://169.254.169.254";
/// Cost Explorer has one endpoint, in us-east-1, whatever the instance's region.
const COST_EXPLORER: &str = "ce.us-east-1.amazonaws.com";

#[derive(Clone, Debug, Default, Serialize, serde::Deserialize)]
pub struct Instance {
    pub id: String,
    pub instance_type: String,
    pub region: String,
    pub zone: String,
    /// The AWS account, which names the app's buckets (see `s3_buckets`).
    #[serde(default)]
    pub account: String,
}

impl Instance {
    /// The app's S3 buckets, named as in infra (`<app>-backups-<account>-<region>`).
    pub fn s3_buckets(&self) -> Vec<String> {
        ["backups", "artifacts"]
            .iter()
            .map(|kind| format!("fade-{kind}-{}-{}", self.account, self.region))
            .collect()
    }
}

#[derive(Clone)]
struct Creds {
    key: String,
    secret: String,
    token: Option<String>,
    expires: i64,
}

pub struct Aws {
    http: reqwest::Client,
    pub instance: Instance,
    creds: Mutex<Option<Creds>>,
}

impl Aws {
    /// The instance's identity, or None when not running on EC2 (development).
    pub async fn detect() -> Option<Self> {
        let http = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(10))
            .connect_timeout(std::time::Duration::from_secs(2))
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .ok()?;
        let token = imds_token(&http).await.ok()?;
        let doc: Value = serde_json::from_str(
            &imds_get(&http, &token, "/latest/dynamic/instance-identity/document")
                .await
                .ok()?,
        )
        .ok()?;
        let field = |k: &str| doc[k].as_str().unwrap_or_default().to_owned();
        Some(Self {
            instance: Instance {
                id: field("instanceId"),
                instance_type: field("instanceType"),
                region: field("region"),
                zone: field("availabilityZone"),
                account: field("accountId"),
            },
            http,
            creds: Mutex::new(None),
        })
    }

    /// The instance role's temporary credentials, refreshed a while before they expire.
    async fn creds(&self) -> anyhow::Result<Creds> {
        if let Some(c) = self.creds.lock().unwrap().clone() {
            if c.expires - crate::db::now() > 10 * 60 {
                return Ok(c);
            }
        }
        let token = imds_token(&self.http).await?;
        let base = "/latest/meta-data/iam/security-credentials/";
        let role = imds_get(&self.http, &token, base).await?;
        let role = role.lines().next().unwrap_or_default().trim().to_owned();
        anyhow::ensure!(!role.is_empty(), "the instance has no role");
        let body: Value =
            serde_json::from_str(&imds_get(&self.http, &token, &format!("{base}{role}")).await?)?;
        let field = |k: &str| body[k].as_str().map(str::to_owned);
        let creds = Creds {
            key: field("AccessKeyId").ok_or_else(|| anyhow::anyhow!("no access key"))?,
            secret: field("SecretAccessKey").ok_or_else(|| anyhow::anyhow!("no secret"))?,
            token: field("Token"),
            expires: field("Expiration")
                .and_then(|e| parse_iso(&e))
                .unwrap_or(crate::db::now() + 15 * 60),
        };
        *self.creds.lock().unwrap() = Some(creds.clone());
        Ok(creds)
    }

    /// Sends a signed request; returns the body, or an error naming AWS's error code.
    #[allow(clippy::too_many_arguments)]
    async fn call(
        &self,
        method: reqwest::Method,
        host: &str,
        service: &str,
        region: &str,
        query: &[(String, String)],
        headers: &[(&str, &str)],
        body: Vec<u8>,
    ) -> anyhow::Result<String> {
        let creds = self.creds().await?;
        let (amz_date, _) = amz_dates(crate::db::now());
        let mut signed: Vec<(String, String)> = headers
            .iter()
            .map(|(k, v)| (k.to_lowercase(), v.to_string()))
            .collect();
        signed.push(("host".into(), host.into()));
        signed.push(("x-amz-date".into(), amz_date.clone()));
        if let Some(t) = &creds.token {
            signed.push(("x-amz-security-token".into(), t.clone()));
        }
        let query = canonical_query(query);
        let auth = authorization(
            method.as_str(),
            "/",
            &query,
            &signed,
            &hex(&Sha256::digest(&body)),
            &creds.key,
            &creds.secret,
            region,
            service,
            &amz_date,
        );
        let url = if query.is_empty() {
            format!("https://{host}/")
        } else {
            format!("https://{host}/?{query}")
        };
        let mut req = self.http.request(method, url).body(body);
        for (k, v) in &signed {
            if k != "host" {
                req = req.header(k.as_str(), v.as_str());
            }
        }
        let res = req.header("authorization", auth).send().await?;
        let status = res.status();
        let text = res.text().await?;
        if !status.is_success() {
            anyhow::bail!("{service} answered {status}: {}", aws_error_code(&text));
        }
        Ok(text)
    }

    /// One CloudWatch metric for this instance: (unix time, value), oldest first.
    pub async fn ec2_metric(
        &self,
        name: &str,
        statistic: &str,
        start: i64,
        end: i64,
    ) -> anyhow::Result<Vec<(i64, f64)>> {
        // CloudWatch returns at most 1,440 points per call.
        let period = (((end - start) / 1440 + 59) / 60 * 60).max(300);
        let id = self.instance.id.clone();
        self.metric(
            "AWS/EC2",
            name,
            &[("InstanceId", &id)],
            statistic,
            start,
            end,
            period,
        )
        .await
    }

    /// The newest daily size, in bytes, of a bucket's objects in one storage
    /// class ("StandardStorage", "GlacierInstantRetrievalStorage"). None if
    /// it holds nothing in that class. S3 publishes these once a day, free.
    pub async fn bucket_bytes(&self, bucket: &str, class: &str) -> anyhow::Result<Option<f64>> {
        let end = crate::db::now();
        let points = self
            .metric(
                "AWS/S3",
                "BucketSizeBytes",
                &[("BucketName", bucket), ("StorageType", class)],
                "Average",
                end - 3 * 86_400,
                end,
                86_400,
            )
            .await?;
        Ok(points.last().map(|p| p.1))
    }

    /// GetMetricStatistics for one metric, dimensions given as (name, value).
    #[allow(clippy::too_many_arguments)]
    async fn metric(
        &self,
        namespace: &str,
        name: &str,
        dimensions: &[(&str, &str)],
        statistic: &str,
        start: i64,
        end: i64,
        period: i64,
    ) -> anyhow::Result<Vec<(i64, f64)>> {
        let q = |k: &str, v: &str| (k.to_owned(), v.to_owned());
        let mut query = vec![
            q("Action", "GetMetricStatistics"),
            q("Version", "2010-08-01"),
            q("Namespace", namespace),
            q("MetricName", name),
            q("StartTime", &iso(start)),
            q("EndTime", &iso(end)),
            q("Period", &period.to_string()),
            q("Statistics.member.1", statistic),
        ];
        for (i, (k, v)) in dimensions.iter().enumerate() {
            query.push(q(&format!("Dimensions.member.{}.Name", i + 1), k));
            query.push(q(&format!("Dimensions.member.{}.Value", i + 1), v));
        }
        let host = format!("monitoring.{}.amazonaws.com", self.instance.region);
        let xml = self
            .call(
                reqwest::Method::GET,
                &host,
                "monitoring",
                &self.instance.region,
                &query,
                &[],
                Vec::new(),
            )
            .await?;
        Ok(parse_datapoints(&xml, statistic))
    }

    /// An SSM parameter's value (decrypted if it's a SecureString), from this
    /// instance's region. Used for the admin list (roles.rs).
    pub async fn ssm_parameter(&self, name: &str) -> anyhow::Result<String> {
        let host = format!("ssm.{}.amazonaws.com", self.instance.region);
        let text = self
            .call(
                reqwest::Method::POST,
                &host,
                "ssm",
                &self.instance.region,
                &[],
                &[
                    ("content-type", "application/x-amz-json-1.1"),
                    ("x-amz-target", "AmazonSSM.GetParameter"),
                ],
                serde_json::to_vec(&json!({ "Name": name, "WithDecryption": true }))?,
            )
            .await?;
        let res: Value = serde_json::from_str(&text)?;
        res["Parameter"]["Value"]
            .as_str()
            .map(str::to_owned)
            .ok_or_else(|| anyhow::anyhow!("parameter {name} has no value"))
    }

    /// What everything tagged App=`app` cost, by service, per month from
    /// `start` (a YYYY-MM-DD) to today. Each call costs $0.01; callers cache.
    pub async fn costs(&self, app: &str, start: &str, end: &str) -> anyhow::Result<Value> {
        let body = json!({
            "TimePeriod": { "Start": start, "End": end },
            "Granularity": "MONTHLY",
            "Metrics": ["UnblendedCost"],
            "Filter": { "Tags": { "Key": "App", "Values": [app] } },
            "GroupBy": [{ "Type": "DIMENSION", "Key": "SERVICE" }],
        });
        let text = self
            .call(
                reqwest::Method::POST,
                COST_EXPLORER,
                "ce",
                "us-east-1",
                &[],
                &[
                    ("content-type", "application/x-amz-json-1.1"),
                    ("x-amz-target", "AWSInsightsIndexService.GetCostAndUsage"),
                ],
                serde_json::to_vec(&body)?,
            )
            .await?;
        let res: Value = serde_json::from_str(&text)?;
        let months: Vec<Value> = res["ResultsByTime"]
            .as_array()
            .map(Vec::as_slice)
            .unwrap_or_default()
            .iter()
            .map(|m| {
                let mut services: Vec<(String, f64)> = m["Groups"]
                    .as_array()
                    .map(Vec::as_slice)
                    .unwrap_or_default()
                    .iter()
                    .map(|g| {
                        let amount = g["Metrics"]["UnblendedCost"]["Amount"]
                            .as_str()
                            .and_then(|a| a.parse().ok())
                            .unwrap_or(0.0);
                        (g["Keys"][0].as_str().unwrap_or("?").to_owned(), amount)
                    })
                    .filter(|(_, a)| *a >= 0.005)
                    .collect();
                services.sort_by(|a, b| b.1.total_cmp(&a.1));
                json!({
                    "start": m["TimePeriod"]["Start"],
                    "end": m["TimePeriod"]["End"],
                    "estimated": m["Estimated"],
                    "total": services.iter().map(|s| s.1).sum::<f64>(),
                    "services": services.iter().map(|(s, a)| json!({ "service": s, "usd": a })).collect::<Vec<_>>(),
                })
            })
            .collect();
        Ok(json!(months))
    }
}

async fn imds_token(http: &reqwest::Client) -> anyhow::Result<String> {
    let res = http
        .put(format!("{IMDS}/latest/api/token"))
        .header("x-aws-ec2-metadata-token-ttl-seconds", "300")
        .timeout(std::time::Duration::from_secs(2))
        .send()
        .await?
        .error_for_status()?;
    Ok(res.text().await?)
}

async fn imds_get(http: &reqwest::Client, token: &str, path: &str) -> anyhow::Result<String> {
    let res = http
        .get(format!("{IMDS}{path}"))
        .header("x-aws-ec2-metadata-token", token)
        .timeout(std::time::Duration::from_secs(2))
        .send()
        .await?
        .error_for_status()?;
    Ok(res.text().await?)
}

// ---------- Signature Version 4 ----------

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn hmac(key: &[u8], data: &str) -> Vec<u8> {
    let mut mac = Hmac::<Sha256>::new_from_slice(key).expect("HMAC takes any key length");
    mac.update(data.as_bytes());
    mac.finalize().into_bytes().to_vec()
}

/// RFC 3986 encoding, as SigV4 wants it: everything but A-Z a-z 0-9 - _ . ~
fn uri_encode(s: &str) -> String {
    s.bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                (b as char).to_string()
            }
            _ => format!("%{b:02X}"),
        })
        .collect()
}

fn canonical_query(query: &[(String, String)]) -> String {
    let mut pairs: Vec<(String, String)> = query
        .iter()
        .map(|(k, v)| (uri_encode(k), uri_encode(v)))
        .collect();
    pairs.sort();
    pairs
        .iter()
        .map(|(k, v)| format!("{k}={v}"))
        .collect::<Vec<_>>()
        .join("&")
}

/// The Authorization header for a request. `headers` are every header
/// that's signed, names in lowercase.
#[allow(clippy::too_many_arguments)]
fn authorization(
    method: &str,
    path: &str,
    canonical_query: &str,
    headers: &[(String, String)],
    payload_hash: &str,
    key: &str,
    secret: &str,
    region: &str,
    service: &str,
    amz_date: &str,
) -> String {
    let mut headers = headers.to_vec();
    headers.sort();
    let canonical_headers: String = headers
        .iter()
        .map(|(k, v)| format!("{k}:{}\n", v.trim()))
        .collect();
    let signed_headers = headers
        .iter()
        .map(|(k, _)| k.as_str())
        .collect::<Vec<_>>()
        .join(";");
    let request = format!(
        "{method}\n{path}\n{canonical_query}\n{canonical_headers}\n{signed_headers}\n{payload_hash}"
    );
    let day = &amz_date[..8];
    let scope = format!("{day}/{region}/{service}/aws4_request");
    let to_sign = format!(
        "AWS4-HMAC-SHA256\n{amz_date}\n{scope}\n{}",
        hex(&Sha256::digest(request.as_bytes()))
    );
    let k = hmac(format!("AWS4{secret}").as_bytes(), day);
    let k = hmac(&k, region);
    let k = hmac(&k, service);
    let k = hmac(&k, "aws4_request");
    let signature = hex(&hmac(&k, &to_sign));
    format!("AWS4-HMAC-SHA256 Credential={key}/{scope}, SignedHeaders={signed_headers}, Signature={signature}")
}

// ---------- dates (UTC, no time zone library needed) ----------

/// (year, month, day) for days since 1970-01-01 (Howard Hinnant's algorithm).
fn civil(days: i64) -> (i64, i64, i64) {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    (yoe + era * 400 + i64::from(m <= 2), m, d)
}

/// Days since 1970-01-01 for a date (the inverse of `civil`).
fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y.rem_euclid(400);
    let mp = (m + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

/// "2026-10-22T09:25:00Z"
pub fn iso(t: i64) -> String {
    let (y, m, d) = civil(t.div_euclid(86_400));
    let s = t.rem_euclid(86_400);
    format!(
        "{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}Z",
        s / 3600,
        s / 60 % 60,
        s % 60
    )
}

/// "2026-10-22"
pub fn ymd(t: i64) -> String {
    iso(t)[..10].to_owned()
}

/// ("20261022T092500Z", "20261022")
fn amz_dates(t: i64) -> (String, String) {
    let s = iso(t).replace(['-', ':'], "");
    let day = s[..8].to_owned();
    (s, day)
}

/// Unix time from "2026-10-22T09:25:00Z" (fractions of a second ignored).
pub fn parse_iso(s: &str) -> Option<i64> {
    let s = s.trim();
    let num = |a: usize, b: usize| s.get(a..b)?.parse::<i64>().ok();
    let days = days_from_civil(num(0, 4)?, num(5, 7)?, num(8, 10)?);
    Some(days * 86_400 + num(11, 13)? * 3600 + num(14, 16)? * 60 + num(17, 19)?)
}

/// The first day of the month before the one holding `t`, as YYYY-MM-DD.
pub fn previous_month_start(t: i64) -> String {
    let (y, m, _) = civil(t.div_euclid(86_400));
    let (y, m) = if m == 1 { (y - 1, 12) } else { (y, m - 1) };
    format!("{y:04}-{m:02}-01")
}

// ---------- responses ----------

/// Datapoints from a GetMetricStatistics XML response, oldest first.
fn parse_datapoints(xml: &str, statistic: &str) -> Vec<(i64, f64)> {
    let tag = |chunk: &str, name: &str| -> Option<String> {
        let open = format!("<{name}>");
        let start = chunk.find(&open)? + open.len();
        let end = chunk[start..].find(&format!("</{name}>"))? + start;
        Some(chunk[start..end].to_owned())
    };
    let mut points: Vec<(i64, f64)> = xml
        .split("<member>")
        .skip(1)
        .filter_map(|m| {
            let t = parse_iso(&tag(m, "Timestamp")?)?;
            let v = tag(m, statistic)?.parse().ok()?;
            Some((t, v))
        })
        .collect();
    points.sort_by_key(|p| p.0);
    points
}

/// AWS's error code from an XML or JSON error body, for the log. Never the whole body.
fn aws_error_code(body: &str) -> String {
    if let Some(start) = body.find("<Code>") {
        let rest = &body[start + 6..];
        if let Some(end) = rest.find("</Code>") {
            return rest[..end].chars().take(80).collect();
        }
    }
    serde_json::from_str::<Value>(body)
        .ok()
        .and_then(|v| v["__type"].as_str().map(|s| s.chars().take(80).collect()))
        .unwrap_or_else(|| "unknown error".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// AWS's published SigV4 example (IAM ListUsers, 2015-08-30 12:36:00 UTC).
    #[test]
    fn signs_like_the_aws_example() {
        let headers = vec![
            (
                "content-type".to_owned(),
                "application/x-www-form-urlencoded; charset=utf-8".to_owned(),
            ),
            ("host".to_owned(), "iam.amazonaws.com".to_owned()),
            ("x-amz-date".to_owned(), "20150830T123600Z".to_owned()),
        ];
        let query = canonical_query(&[
            ("Version".into(), "2010-05-08".into()),
            ("Action".into(), "ListUsers".into()),
        ]);
        assert_eq!(query, "Action=ListUsers&Version=2010-05-08");
        let auth = authorization(
            "GET",
            "/",
            &query,
            &headers,
            &hex(&Sha256::digest(b"")),
            "AKIDEXAMPLE",
            "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
            "us-east-1",
            "iam",
            "20150830T123600Z",
        );
        assert_eq!(
            auth,
            "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/iam/aws4_request, \
             SignedHeaders=content-type;host;x-amz-date, \
             Signature=5d672d79c15b13162d9279b0855cfba6789a8edb4c82c400e06b5924a6f2b5d7"
        );
    }

    #[test]
    fn bucket_names_follow_infra() {
        let i = Instance {
            account: "705059992745".into(),
            region: "us-east-1".into(),
            ..Default::default()
        };
        assert_eq!(
            i.s3_buckets(),
            [
                "fade-backups-705059992745-us-east-1",
                "fade-artifacts-705059992745-us-east-1"
            ]
        );
    }

    #[test]
    fn encodes_query_values() {
        assert_eq!(
            uri_encode("2026-10-22T09:25:00Z"),
            "2026-10-22T09%3A25%3A00Z"
        );
        assert_eq!(uri_encode("AWS/EC2"), "AWS%2FEC2");
        assert_eq!(uri_encode("a b~_.-"), "a%20b~_.-");
    }

    #[test]
    fn dates_round_trip() {
        for t in [0, 951_782_400, 1_440_938_160, 1_792_659_900, 4_102_444_799] {
            assert_eq!(parse_iso(&iso(t)), Some(t), "{}", iso(t));
        }
        assert_eq!(iso(1_440_938_160), "2015-08-30T12:36:00Z");
        assert_eq!(amz_dates(1_440_938_160).0, "20150830T123600Z");
        assert_eq!(iso(951_782_400), "2000-02-29T00:00:00Z"); // leap day
        assert_eq!(
            parse_iso("2026-10-23T07:00:00.123Z"),
            parse_iso("2026-10-23T07:00:00Z")
        );
        assert_eq!(
            previous_month_start(parse_iso("2026-10-22T00:00:00Z").unwrap()),
            "2026-09-01"
        );
        assert_eq!(
            previous_month_start(parse_iso("2026-01-05T00:00:00Z").unwrap()),
            "2025-12-01"
        );
        assert_eq!(
            ymd(parse_iso("2026-10-22T23:59:59Z").unwrap()),
            "2026-10-22"
        );
    }

    #[test]
    fn reads_cloudwatch_datapoints() {
        let xml = "<GetMetricStatisticsResponse><GetMetricStatisticsResult><Datapoints>\
            <member><Timestamp>2026-10-22T09:30:00Z</Timestamp><Average>141.5</Average><Unit>Count</Unit></member>\
            <member><Timestamp>2026-10-22T09:25:00Z</Timestamp><Average>144</Average><Unit>Count</Unit></member>\
            </Datapoints><Label>CPUCreditBalance</Label></GetMetricStatisticsResult></GetMetricStatisticsResponse>";
        let t = parse_iso("2026-10-22T09:25:00Z").unwrap();
        assert_eq!(
            parse_datapoints(xml, "Average"),
            vec![(t, 144.0), (t + 300, 141.5)]
        );
        assert!(parse_datapoints(xml, "Sum").is_empty());
    }

    #[test]
    fn error_codes_not_bodies() {
        assert_eq!(
            aws_error_code("<ErrorResponse><Error><Code>AccessDenied</Code><Message>User arn:aws:sts::1:x</Message></Error></ErrorResponse>"),
            "AccessDenied"
        );
        assert_eq!(
            aws_error_code(r#"{"__type":"AccessDeniedException","Message":"no"}"#),
            "AccessDeniedException"
        );
    }
}
