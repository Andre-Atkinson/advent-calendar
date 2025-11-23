<#
.SYNOPSIS
    Simple script to retry failed Veeam backup jobs until successful.

.DESCRIPTION
    Checks all backup jobs for failed status and retries them automatically.
    Sends email notification when retrying a job.
    Does not retry jobs that are currently running.

.NOTES
    Author: Auto-generated
    Date: 2025-11-23
#>

# =============================================================================
# CONFIGURATION
# =============================================================================

# Veeam Backup & Replication REST API settings
$VBRServer = ""
$VBRPort = 9419
$Username = "veeamadmin"
$Password = ""  # Change this to your password
$BaseUrl = "https://$($VBRServer):$($VBRPort)/api/v1"
$ApiVersion = "1.3-rev1"

# Email settings (Optional - leave blank to disable email notifications)
$SmtpServer = ""  # e.g., "smtp.office365.com"
$SmtpPort = 587
$SmtpUsername = ""  # e.g., "user@domain.com"
$SmtpPassword = ""  # SMTP password
$EmailFrom = ""  # e.g., "backup-admin@westcoastlabs.xyz"
$EmailTo = ""      # e.g., "backup-admin@westcoastlabs.xyz"
$EmailSubject = "Veeam Job Retry Notification"

# =============================================================================
# FUNCTIONS
# =============================================================================

function Get-VBRAccessToken {
    param(
        [string]$Server,
        [string]$Username,
        [securestring]$Password
    )
    
    $cred = New-Object System.Management.Automation.PSCredential($Username, $Password)
    $plainPassword = $cred.GetNetworkCredential().Password
    
    $body = @{
        grant_type = "password"
        username = $Username
        password = $plainPassword
    }
    
    $headers = @{
        "x-api-version" = $ApiVersion
        "Content-Type" = "application/x-www-form-urlencoded"
    }
    
    try {
        $response = Invoke-RestMethod -Uri "https://$($Server):$($VBRPort)/api/oauth2/token" `
            -Method Post -Body $body -Headers $headers -SkipCertificateCheck
        return $response.access_token
    }
    catch {
        Write-Error "Failed to authenticate: $_"
        return $null
    }
}

function Get-VBRJobs {
    param(
        [string]$Token
    )
    
    $headers = @{
        "Authorization" = "Bearer $Token"
        "x-api-version" = $ApiVersion
        "Accept" = "application/json"
    }
    
    try {
        $response = Invoke-RestMethod -Uri "$BaseUrl/jobs" -Method Get -Headers $headers -SkipCertificateCheck
        return $response.data
    }
    catch {
        Write-Error "Failed to get jobs: $_"
        return $null
    }
}

function Get-VBRJobStatus {
    param(
        [string]$Token,
        [string]$JobId
    )
    
    $headers = @{
        "Authorization" = "Bearer $Token"
        "x-api-version" = $ApiVersion
        "Accept" = "application/json"
    }
    
    try {
        $response = Invoke-RestMethod -Uri "$BaseUrl/jobs/states" -Method Get -Headers $headers -SkipCertificateCheck
        $jobStatus = $response.data | Where-Object { $_.id -eq $JobId }
        return $jobStatus
    }
    catch {
        Write-Error "Failed to get job status: $_"
        return $null
    }
}

function Start-VBRJob {
    param(
        [string]$Token,
        [string]$JobId
    )
    
    $headers = @{
        "Authorization" = "Bearer $Token"
        "x-api-version" = $ApiVersion
        "Accept" = "application/json"
    }
    
    try {
        $response = Invoke-RestMethod -Uri "$BaseUrl/jobs/$JobId/start" -Method Post -Headers $headers -SkipCertificateCheck
        return $true
    }
    catch {
        Write-Error "Failed to start job: $_"
        return $false
    }
}

function Send-RetryNotification {
    param(
        [string]$JobName,
        [string]$LastResult
    )
    
    # Skip if email not configured
    if ([string]::IsNullOrWhiteSpace($SmtpServer) -or [string]::IsNullOrWhiteSpace($EmailFrom) -or [string]::IsNullOrWhiteSpace($EmailTo)) {
        Write-Host "  Email notifications not configured, skipping..." -ForegroundColor Gray
        return
    }
    
    $emailBody = @"
A Veeam backup job has been automatically retried.

Job Name: $JobName
Previous Status: $LastResult
Action: Job retry initiated
Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

This is an automated notification from the Veeam job retry script.
"@
    
    try {
        $smtpSecurePassword = ConvertTo-SecureString $SmtpPassword -AsPlainText -Force
        $smtpCredential = New-Object System.Management.Automation.PSCredential($SmtpUsername, $smtpSecurePassword)
        
        Send-MailMessage -SmtpServer $SmtpServer -Port $SmtpPort -UseSsl `
            -From $EmailFrom -To $EmailTo -Subject $EmailSubject `
            -Body $emailBody -Credential $smtpCredential
        
        Write-Host "  Email notification sent to $EmailTo" -ForegroundColor Green
    }
    catch {
        Write-Warning "Failed to send email notification: $_"
    }
}

# =============================================================================
# MAIN SCRIPT
# =============================================================================

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Veeam Failed Job Retry Script" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# Convert password to secure string
$SecurePassword = ConvertTo-SecureString $Password -AsPlainText -Force

# Authenticate
Write-Host "Authenticating to Veeam REST API..." -ForegroundColor Yellow
$token = Get-VBRAccessToken -Server $VBRServer -Username $Username -Password $SecurePassword

if (-not $token) {
    Write-Host "Authentication failed. Exiting." -ForegroundColor Red
    exit 1
}

Write-Host "Authentication successful!`n" -ForegroundColor Green

# Get all jobs
Write-Host "Retrieving all backup jobs..." -ForegroundColor Yellow
$jobs = Get-VBRJobs -Token $token

if (-not $jobs) {
    Write-Host "No jobs found or failed to retrieve jobs. Exiting." -ForegroundColor Red
    exit 1
}

Write-Host "Found $($jobs.Count) jobs`n" -ForegroundColor Green

# Check each job and retry if failed
$retriedJobs = 0

foreach ($job in $jobs) {
    Write-Host "Checking job: $($job.name)" -ForegroundColor Cyan
    
    # Get job status
    $status = Get-VBRJobStatus -Token $token -JobId $job.id
    
    if (-not $status) {
        Write-Host "  Could not retrieve status, skipping..." -ForegroundColor Yellow
        continue
    }
    
    Write-Host "  Last Result: $($status.lastResult)" -ForegroundColor Gray
    Write-Host "  Current Status: $($status.status)" -ForegroundColor Gray
    
    # Check if job is currently running (status will be "Running")
    if ($status.status -eq "Running") {
        Write-Host "  Status: Job is currently running, skipping..." -ForegroundColor Yellow
        continue
    }
    
    # Check if last result was not successful
    if ($status.lastResult -and $status.lastResult -ne "Success" -and $status.lastResult -ne "None") {
        Write-Host "  Status: FAILED - Retrying job..." -ForegroundColor Red
        
        # Start the job
        $started = Start-VBRJob -Token $token -JobId $job.id
        
        if ($started) {
            Write-Host "  Job retry initiated successfully!" -ForegroundColor Green
            $retriedJobs++
            
            # Send email notification
            Send-RetryNotification -JobName $job.name -LastResult $status.lastResult
        }
        else {
            Write-Host "  Failed to retry job!" -ForegroundColor Red
        }
    }
    else {
        Write-Host "  Status: OK - No retry needed" -ForegroundColor Green
    }
    
    Write-Host ""
}

# Summary
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Summary" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Total jobs checked: $($jobs.Count)" -ForegroundColor White
Write-Host "Jobs retried: $retriedJobs" -ForegroundColor White
Write-Host "`nScript completed at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Green
Write-Host "========================================`n" -ForegroundColor Cyan
