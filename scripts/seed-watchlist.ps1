# Upserts the companies from a CSV (Ticker,Name,Exchange) into the watchlist table.
# Needs `az login` and the azd environment (azd provision grants you Storage Table Data Contributor).
#   ./scripts/seed-watchlist.ps1 [-Csv watchlist.example.csv]
param([string]$Csv = "$PSScriptRoot/../watchlist.example.csv")

$ErrorActionPreference = 'Stop'
$env = @{}
azd env get-values | ForEach-Object { if ($_ -match '^([^=]+)="?(.*?)"?$') { $env[$Matches[1]] = $Matches[2] } }
$account = $env['STORAGE_ACCOUNT_NAME']
$table = $env['WATCHLIST_TABLE']
if (-not $account) { throw 'STORAGE_ACCOUNT_NAME not found in the azd environment. Run azd provision first.' }

foreach ($row in Import-Csv $Csv) {
    az storage entity insert --auth-mode login --account-name $account --table-name $table `
        --if-exists replace --entity PartitionKey=stocks RowKey=$($row.Ticker) Name="$($row.Name)" Exchange="$($row.Exchange)" Active=true:boolean -o none
    Write-Host "Upserted $($row.Ticker) ($($row.Name))"
}
