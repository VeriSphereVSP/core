#!/usr/bin/env python3
import argparse, os, json
import gspread
from oauth2client.service_account import ServiceAccountCredentials

parser = argparse.ArgumentParser()
parser.add_argument("--sheet", required=True)
parser.add_argument("--title", required=True)
parser.add_argument("--labels", required=True)
parser.add_argument("--actor", required=True)
parser.add_argument("--status", required=True)
parser.add_argument("--repo", required=True)
parser.add_argument("--url", required=True)
args = parser.parse_args()

scope = ["https://www.googleapis.com/auth/spreadsheets"]
creds = ServiceAccountCredentials.from_json_keyfile_name(".verisphere/scripts/key.json", scope)
client = gspread.authorize(creds)
sheet = client.open_by_key(args.sheet).sheet1

# labels comes from GitHub as JSON; keep as text in the sheet
sheet.append_row([
    args.repo,
    args.title,
    args.labels,
    args.actor,
    args.status,
    args.url
])

print("✅ Bounty log row appended.")

