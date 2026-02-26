# APOC²

AI-powered garment intelligence platform for eBay resellers. Upload photos of clothing items and APOC² uses Claude AI to analyze brand, size, material, condition, and pricing — then lists directly to eBay with optimized titles, descriptions, item specifics, and market-based pricing from sold comps.

## Prerequisites

- **AWS CLI v2** — configured with IAM credentials that have Bedrock access
- **Docker** — for building and running the container
- **eBay Developer Account** — production keyset from [developer.ebay.com](https://developer.ebay.com)
- **Python 3.11+** — for local development without Docker

## Local Development

```bash
# 1. Clone and enter the repo
git clone https://github.com/tien1868/apoc_app.git
cd apoc_app

# 2. Create environment file
cp .env.example .env
# Edit .env and fill in your AWS + eBay credentials

# 3. Install dependencies
pip install -r requirements.txt

# 4. Run the server
uvicorn app:app --host 0.0.0.0 --port 8080 --reload
```

The API will be available at `http://localhost:8080`. Test it with `curl http://localhost:8080/health`.

## Production Deploy

### Option A: Run deploy.sh manually

```bash
# Requires: AWS CLI configured, Docker running, .env file populated
chmod +x deploy.sh
./deploy.sh
```

This will build the Docker image, push to ECR, create/update the App Runner service, wait for it to reach RUNNING status, and run a health check.

### Option B: Push to main (CI/CD)

Pushing to the `main` branch triggers the GitHub Actions workflow at `.github/workflows/deploy.yml`. Configure these GitHub Secrets first:

| Secret | Description |
|---|---|
| `AWS_ACCESS_KEY_ID` | IAM access key with ECR + App Runner + Bedrock permissions |
| `AWS_SECRET_ACCESS_KEY` | IAM secret key |
| `AWS_REGION` | AWS region (e.g. `us-east-1`) |
| `EBAY_APP_ID` | eBay application ID (production keyset) |
| `EBAY_DEV_ID` | eBay developer ID |
| `EBAY_CERT_ID` | eBay certificate ID |
| `EBAY_RUNAME` | eBay redirect URL name for OAuth |

## API Endpoints

| Method | Path | Description | Auth |
|---|---|---|---|
| `GET` | `/health` | Health check, uptime, metrics | No |
| `POST` | `/analyze` | Analyze garment photos with Claude AI | No |
| `POST` | `/remove-bg` | Remove background from garment images | No |
| `POST` | `/comps` | Fetch eBay sold comps (Finding API) | No |
| `POST` | `/sold-history` | Sell-through rate and market intelligence | No |
| `POST` | `/price-recommend` | 3-tier price recommendation (quick/market/premium) | No |
| `GET` | `/ebay-auth-url` | Get eBay OAuth authorization URL | No |
| `POST` | `/ebay-complete` | Complete eBay OAuth token exchange | No |
| `POST` | `/ebay-refresh` | Refresh eBay access token | No |
| `POST` | `/publish` | List item on eBay | eBay OAuth |
| `POST` | `/publish-multi` | List on eBay + format for Poshmark/Mercari | eBay OAuth |
| `POST` | `/queue/add` | Add item to batch listing queue | No |
| `GET` | `/queue` | List queued items | No |
| `POST` | `/queue/process` | Process all pending queue items | eBay OAuth |
| `DELETE` | `/queue/{id}` | Remove item from queue | No |
| `GET` | `/ebay-callback` | OAuth redirect handler (browser) | No |

## Architecture

- **Backend**: FastAPI + uvicorn on AWS App Runner (this repo)
- **Frontend**: Vanilla HTML/JS on Vercel (`index.html`, `bulk.html`)
- **AI**: Claude Sonnet via AWS Bedrock (cross-region inference)
- **Background Removal**: rembg with u2netp model
- **eBay Integration**: Trading API (XML), Finding API (REST), OAuth 2.0
