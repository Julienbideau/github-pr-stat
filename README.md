# GitHub PR Stats - Pull Request Analysis Script

This script analyzes GitHub Pull Requests with a specific label and generates detailed statistics, including:
- Total number of PRs
- Statistics by creator
- PR status (merged, open, closed)
- Most active commenters
- Average resolution time (with and without weekends)

## Prerequisites

Before using this script, you need to install the following dependencies:

### 1. jq

`jq` is a command-line tool for processing JSON.

**On macOS:**
```bash
brew install jq
```

**On Ubuntu/Debian:**
```bash
sudo apt-get install jq
```

**On CentOS/RHEL:**
```bash
sudo yum install jq
```

### 2. bc

`bc` is a command-line calculator needed for time calculations.

**On macOS:**
```bash
brew install bc
```

**On Ubuntu/Debian:**
```bash
sudo apt-get install bc
```

**On CentOS/RHEL:**
```bash
sudo yum install bc
```

## Creating a GitHub Token

To use this script, you need a GitHub personal access token:

1. Log in to your GitHub account
2. Click on your profile picture in the top right corner, then click "Settings"
3. In the left menu, click "Developer settings"
4. Click "Personal access tokens" then "Tokens (classic)"
5. Click "Generate new token" then "Generate new token (classic)"
6. Give your token a name (e.g., "PR Stats Script")
7. Select the following scopes:
   - `repo` (to access repositories)
   - `read:org` (if you're analyzing organization repositories)
8. Click "Generate token"
9. **Important**: Copy the generated token immediately, as you won't be able to see it again after leaving this page

## Usage Instructions

1. Create a file named `github_pr_stats.sh` with the script code
2. Make the script executable:
   ```bash
   chmod +x github_pr_stats.sh
   ```
3. Run the script with the required parameters:
   ```bash
   ./github_pr_stats.sh <owner/repo> <label> <github_token> [max_pages]
   ```

### Usage Examples

```bash
# Analyze PRs with the "bug" label in the doctolib/main-app repository
./github_pr_stats.sh doctolib/main-app bug ghp_your_token_here

# Analyze PRs with the "feature" label and retrieve up to 20 pages
./github_pr_stats.sh doctolib/main-app feature ghp_your_token_here 20

# Analyze PRs with the "PIKA" label
./github_pr_stats.sh doctolib/content-moderation PIKA ghp_your_token_here
```

## Features

- **Label filtering**: Analyzes only PRs with the specified label
- **Time limitation**: Analyzes PRs created in the last 3 months
- **Pagination**: Retrieves multiple pages of results (default 10, configurable)
- **Detailed statistics**:
  - Total number of PRs
  - Number of PRs by creator
  - PR status (merged, open, closed)
  - Most active commenters
  - Average resolution time by creator
  - Global average time (with and without weekends)

## Notes

- The script is optimized for macOS. If you're using Linux, you may need to adjust the `date` commands.
- The script respects GitHub API limits by adding delays between requests.
- For large repositories, consider increasing the `MAX_PAGES` value to retrieve more PRs.
- Comment statistics are based on a sample of the first 50 PRs to avoid overloading the API.

## Troubleshooting

- **"Token invalid" error**: Check that your token is correct and hasn't expired
- **"Rate limit exceeded" error**: You've hit the GitHub API limit, wait for the limit to reset
- **No PRs found**: Verify that the label is correct (case-sensitive) and that PRs with this label exist in the specified time period
