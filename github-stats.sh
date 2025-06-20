#!/bin/bash

# GitHub Pull Request Analysis Script with customizable label and multiple repositories
# Usage: ./github_pr_stats.sh <repo1,repo2,repo3> <label> <github_token> [max_pages] [disable_sampling]

# Check for required parameters
if [ $# -lt 3 ]; then
    echo "Usage: $0 <repositories> <label> <github_token> [max_pages] [disable_sampling]"
    echo "Example: $0 myorga/main-app,myorga/runtime YOURLABEL YOUR_GITHUB_TOKEN 10 true"
    echo "Error: Repositories and GitHub token are required."
    echo "Optional: max_pages (default: 10), disable_sampling (true/false, default: false)"
    echo "Note: Repositories should be comma-separated (no spaces)"
    exit 1
fi

REPOSITORIES=$1
LABEL=$2
TOKEN=$3
MAX_PAGES=${4:-10}
DISABLE_SAMPLING=${5:-false}

# Parse repositories into an array
IFS=',' read -ra REPO_ARRAY <<< "$REPOSITORIES"

# Get the directory where the script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMENTS_OUTPUT_DIR="${SCRIPT_DIR}/comments_output"

echo "Analyzing PRs with label '$LABEL' for repositories: ${REPO_ARRAY[*]} (max $MAX_PAGES pages each)"
if [ "$DISABLE_SAMPLING" = "true" ]; then
    echo "Sampling disabled: all PRs will be analyzed for comments and reviews"
else
    echo "Sampling enabled: a representative sample will be used for comments and reviews"
fi
echo "Comments will be saved to: $COMMENTS_OUTPUT_DIR"

# Create comments output directory if it doesn't exist
mkdir -p "$COMMENTS_OUTPUT_DIR"

# Calculate date from 3 months ago in ISO 8601 format
THREE_MONTHS_AGO=$(date -v-3m +%Y-%m-%dT%H:%M:%SZ)
echo "Retrieving PRs since: $THREE_MONTHS_AGO"

# Create a temporary directory
TEMP_DIR=$(mktemp -d)
PR_FILE="${TEMP_DIR}/prs.json"
ALL_PR_NUMBERS="${TEMP_DIR}/all_pr_numbers.txt"  # Store all PR numbers for sampling
TOTAL_COUNT_FILE="${TEMP_DIR}/total_count.txt"
CREATORS_FILE="${TEMP_DIR}/creators.txt"  # Specific file for creators
STATES_FILE="${TEMP_DIR}/states.txt"      # Specific file for states
MERGED_FILE="${TEMP_DIR}/merged.txt"      # Specific file for merged PRs
COMMENTERS_FILE="${TEMP_DIR}/commenters.txt"
REVIEWERS_BY_PR_FILE="${TEMP_DIR}/reviewers_by_pr.txt"  # For PR review coverage
PR_TIMES_FILE="${TEMP_DIR}/pr_times.csv"
REPO_STATS_FILE="${TEMP_DIR}/repo_stats.txt"  # Track stats per repository

# Initialize files
echo "0" > "$TOTAL_COUNT_FILE"
touch "$PR_FILE" "$ALL_PR_NUMBERS" "$CREATORS_FILE" "$STATES_FILE" "$MERGED_FILE" "$COMMENTERS_FILE" "$REVIEWERS_BY_PR_FILE" "$REPO_STATS_FILE"
echo "creator,number,created_at,merged_at,hours,business_hours,repository" > "$PR_TIMES_FILE"

# Write the beginning of the JSON array
echo "[" > "$PR_FILE"
first_pr=true

# Function to check if a date is a weekend (Saturday or Sunday)
is_weekend() {
    local date_str=$1
    # The -f format must match the input date format
    local day_of_week=$(date -jf "%Y-%m-%dT%H:%M:%SZ" "$date_str" +%u)
    # %u gives 1-7 where 6 and 7 are Saturday and Sunday
    [ "$day_of_week" -eq 6 ] || [ "$day_of_week" -eq 7 ]
}

# Function to calculate business hours between two dates
business_hours() {
    local start_date=$1
    local end_date=$2
    
    # Convert to Unix timestamps
    local start_ts=$(date -jf "%Y-%m-%dT%H:%M:%SZ" "$start_date" +%s)
    local end_ts=$(date -jf "%Y-%m-%dT%H:%M:%SZ" "$end_date" +%s)
    
    # Calculate total hours
    local total_hours=$(echo "scale=1; ($end_ts - $start_ts) / 3600" | bc)
    
    # Calculate number of complete days
    local days=$(echo "scale=0; ($end_ts - $start_ts) / 86400" | bc)
    
    # Count weekends
    local weekend_days=0
    local current_ts=$start_ts
    
    for ((i=0; i<days; i++)); do
        # Format the current date
        local current_date=$(date -r $current_ts -u +%Y-%m-%dT%H:%M:%SZ)
        
        # Check if it's a weekend
        if is_weekend "$current_date"; then
            weekend_days=$((weekend_days + 1))
        fi
        
        # Advance by one day
        current_ts=$((current_ts + 24 * 3600))
    done
    
    # Subtract weekend hours (24 hours per weekend day)
    local business_hours=$(echo "scale=1; $total_hours - ($weekend_days * 24)" | bc)
    
    echo $business_hours
}

# Function to save comment to user's file
save_comment_to_file() {
    local user=$1
    local pr_number=$2
    local comment_body=$3
    local comment_date=$4
    local comment_url=$5
    local repository=$6
    
    # Sanitize username for filename (replace special characters with underscores)
    local safe_username=$(echo "$user" | sed 's/[^a-zA-Z0-9._-]/_/g')
    local user_file="${COMMENTS_OUTPUT_DIR}/${safe_username}_comments.md"
    
    # Create user file with header if it doesn't exist
    if [ ! -f "$user_file" ]; then
        cat > "$user_file" << EOF
# Comments by $user

Repositories: ${REPO_ARRAY[*]}
Label: $LABEL
Generated on: $(date)

---

EOF
    fi
    
    # Append comment to user's file
    cat >> "$user_file" << EOF
## $repository - PR #$pr_number - $(echo "$comment_date" | cut -d'T' -f1)

**Repository:** $repository
**Date:** $comment_date
**URL:** $comment_url

$comment_body

---

EOF
}

# Function to fetch PRs for a single repository
fetch_prs_for_repo() {
    local repo=$1
    local repo_pr_count=0
    
    echo "Processing repository: $repo"
    
    local page=1
    while [ $page -le $MAX_PAGES ]; do
        echo "  Retrieving page $page for $repo..."
        
        # Build the search query
        QUERY="repo:$repo is:pr label:$LABEL created:>=$THREE_MONTHS_AGO"
        ENCODED_QUERY=$(echo "$QUERY" | sed 's/ /%20/g')
        
        # Step 1: Search for PRs with the specified label (GitHub treats PRs as a type of issue)
        response=$(curl -s -H "Authorization: token $TOKEN" \
                       -H "Accept: application/vnd.github.v3+json" \
                       "https://api.github.com/search/issues?q=$ENCODED_QUERY&page=$page&per_page=100")
        
        # Check if the response contains an error
        if echo "$response" | jq -e 'has("message")' > /dev/null; then
            echo "  API Error for $repo: $(echo "$response" | jq -r '.message')"
            break
        fi
        
        # Extract PR numbers
        items=$(echo "$response" | jq '.items')
        item_count=$(echo "$items" | jq 'length')
        echo "  Found $item_count PRs on page $page for $repo"
        
        # If no items, stop pagination for this repo
        if [ "$item_count" -eq 0 ]; then
            echo "  Empty page for $repo, ending pagination."
            break
        fi
        
        # For each PR, retrieve the details and add to the file
        echo "$items" | jq -c '.[]' | while read -r item; do
            pr_number=$(echo "$item" | jq -r '.number')
            echo "  Retrieving details for $repo PR #$pr_number..."
            
            # Store PR number with repository for later sampling
            echo "$repo:$pr_number" >> "$ALL_PR_NUMBERS"
            
            # Step 2: Retrieve complete details for each PR
            pr_details=$(curl -s -H "Authorization: token $TOKEN" \
                             -H "Accept: application/vnd.github.v3+json" \
                             "https://api.github.com/repos/$repo/pulls/$pr_number")
            
            # Check if the response is valid
            if echo "$pr_details" | jq -e 'has("url")' > /dev/null; then
                # Add repository information to the PR details
                pr_details_with_repo=$(echo "$pr_details" | jq --arg repo "$repo" '. + {repository: $repo}')
                
                # Add the PR to the JSON file, handling comma for valid JSON format
                if [ "$first_pr" = true ]; then
                    first_pr=false
                else
                    echo "," >> "$PR_FILE"
                fi
                
                # Write the complete PR to the file
                echo "$pr_details_with_repo" >> "$PR_FILE"
                
                # Increment the total PR counter
                current_count=$(cat "$TOTAL_COUNT_FILE")
                current_count=$((current_count + 1))
                echo "$current_count" > "$TOTAL_COUNT_FILE"
                
                # Increment repo-specific counter
                repo_pr_count=$((repo_pr_count + 1))
                
                # Extract and store important information directly
                creator=$(echo "$pr_details" | jq -r '.user.login')
                state=$(echo "$pr_details" | jq -r '.state')
                is_merged=$(echo "$pr_details" | jq -r '.merged')
                
                # Store in separate files for reliable counting (with repo prefix for creators)
                echo "$repo:$creator" >> "$CREATORS_FILE"
                echo "$state" >> "$STATES_FILE"
                if [ "$is_merged" = "true" ]; then
                    echo "true" >> "$MERGED_FILE"
                fi
                
                # Extract data for average time calculation
                created_at=$(echo "$pr_details" | jq -r '.created_at')
                merged_at=$(echo "$pr_details" | jq -r '.merged_at')
                
                if [ "$is_merged" = "true" ] && [ "$merged_at" != "null" ]; then
                    # Calculate difference in hours (total time)
                    created_ts=$(date -jf "%Y-%m-%dT%H:%M:%SZ" "$created_at" +%s)
                    merged_ts=$(date -jf "%Y-%m-%dT%H:%M:%SZ" "$merged_at" +%s)
                    hours=$(echo "scale=1; ($merged_ts - $created_ts) / 3600" | bc)
                    
                    # Calculate business hours (exclude weekends)
                    business_hrs=$(business_hours "$created_at" "$merged_at")
                    
                    # Add to CSV file with repository information
                    echo "$creator,$pr_number,$created_at,$merged_at,$hours,$business_hrs,$repo" >> "$PR_TIMES_FILE"
                fi
            else
                echo "  Error retrieving details for $repo PR #$pr_number"
            fi
            
            # Increase delay between requests
            sleep 0.3
        done
        
        # If less than 100 items, it's the last page for this repo
        if [ "$item_count" -lt 100 ]; then
            echo "  Less than 100 results for $repo, ending pagination."
            break
        fi
        
        page=$((page + 1))
        sleep 0.5
    done
    
    # Record stats for this repository
    echo "$repo:$repo_pr_count" >> "$REPO_STATS_FILE"
    echo "Completed processing $repo: $repo_pr_count PRs found"
}

# First pass: get all PR numbers and basic stats for all repositories
fetch_prs() {
    for repo in "${REPO_ARRAY[@]}"; do
        fetch_prs_for_repo "$repo"
    done
}

# Second pass: collect comments and reviews from a representative sample or all PRs
collect_comments_and_reviews() {
    MAX_COMMENTS_PR=50  # Limit for total number of PRs for comments if sampling is enabled
    
    echo "Collecting detailed data for comments and reviews..."
    
    # Get total number of PRs
    TOTAL_PRS=$(cat "$TOTAL_COUNT_FILE")
    
    if [ $TOTAL_PRS -eq 0 ]; then
        echo "No PRs found, skipping detailed analysis."
        return
    fi
    
    # Determine which PRs to analyze
    if [ "$DISABLE_SAMPLING" = "true" ]; then
        # Analyze all PRs if sampling is disabled
        SAMPLE_PRS=$(cat "$ALL_PR_NUMBERS")
        echo "Sampling disabled: analyzing all $TOTAL_PRS PRs for comments and reviews"
    else
        # Select a representative sample if sampling is enabled
        if [ $TOTAL_PRS -le $MAX_COMMENTS_PR ]; then
            # If we have fewer PRs than our limit, analyze all of them
            SAMPLE_PRS=$(cat "$ALL_PR_NUMBERS")
            echo "Small dataset: analyzing all $TOTAL_PRS PRs for comments and reviews"
        else
            # Otherwiseelse
            # Otherwise, take a random sample
            SAMPLE_PRS=$(sort -R "$ALL_PR_NUMBERS" | head -$MAX_COMMENTS_PR)
            echo "Sampling enabled: analyzing $MAX_COMMENTS_PR PRs out of $TOTAL_PRS for comments and reviews"
        fi
    fi
    
    # For each sampled PR, collect comments and reviews
    for repo_pr in $SAMPLE_PRS; do
        # Split repo:pr_number
        repo=$(echo "$repo_pr" | cut -d':' -f1)
        pr_number=$(echo "$repo_pr" | cut -d':' -f2)
        
        echo "Collecting detailed data for $repo PR #$pr_number..."
        
        # Collect review comments (inline code comments)
        review_comments_url="https://api.github.com/repos/$repo/pulls/$pr_number/comments"
        review_comments=$(curl -s -H "Authorization: token $TOKEN" \
                             -H "Accept: application/vnd.github.v3+json" \
                             "$review_comments_url")
        
        # Process review comments and save to individual files
        echo "$review_comments" | jq -c '.[]' 2>/dev/null | while read -r comment; do
            if [ -n "$comment" ] && [ "$comment" != "null" ]; then
                user=$(echo "$comment" | jq -r '.user.login')
                body=$(echo "$comment" | jq -r '.body')
                created_at=$(echo "$comment" | jq -r '.created_at')
                html_url=$(echo "$comment" | jq -r '.html_url')
                
                if [ "$user" != "null" ] && [ "$body" != "null" ]; then
                    # Add to commenters file for statistics
                    echo "$user" >> "$COMMENTERS_FILE"
                    
                    # Save comment to user's individual file
                    save_comment_to_file "$user" "$pr_number" "$body" "$created_at" "$html_url" "$repo"
                fi
            fi
        done
        
        # Collect general PR reviews (approve/request changes/comment)
        reviews_url="https://api.github.com/repos/$repo/pulls/$pr_number/reviews"
        reviews=$(curl -s -H "Authorization: token $TOKEN" \
                    -H "Accept: application/vnd.github.v3+json" \
                    "$reviews_url")
        
        # Process reviews and save to individual files
        echo "$reviews" | jq -c '.[]' 2>/dev/null | while read -r review; do
            if [ -n "$review" ] && [ "$review" != "null" ]; then
                user=$(echo "$review" | jq -r '.user.login')
                body=$(echo "$review" | jq -r '.body')
                state=$(echo "$review" | jq -r '.state')
                created_at=$(echo "$review" | jq -r '.submitted_at')
                html_url=$(echo "$review" | jq -r '.html_url')
                
                if [ "$user" != "null" ]; then
                    # Add to reviewers file for statistics (unique reviewers per PR)
                    echo "$repo:$pr_number $user" >> "$REVIEWERS_BY_PR_FILE"
                    
                    # Save review to user's individual file if there's a body or it's not just a comment
                    if [ "$body" != "null" ] && [ "$body" != "" ]; then
                        review_content="**Review State:** $state\n\n$body"
                        save_comment_to_file "$user" "$pr_number" "$review_content" "$created_at" "$html_url" "$repo"
                    elif [ "$state" != "COMMENTED" ]; then
                        # Save approve/request changes even without body
                        review_content="**Review State:** $state"
                        save_comment_to_file "$user" "$pr_number" "$review_content" "$created_at" "$html_url" "$repo"
                    fi
                fi
            fi
        done
        
        sleep 0.3  # Avoid API rate limits
    done
    
    ANALYZED_COUNT=$(echo "$SAMPLE_PRS" | wc -l | tr -d ' ')
    echo "Detailed analysis completed for $ANALYZED_COUNT PRs."
    echo "Comments saved to individual files in: $COMMENTS_OUTPUT_DIR"
}

# Fetch PRs for all repositories
fetch_prs

# Close the JSON array
echo "]" >> "$PR_FILE"

# Read the total number of PRs from the file
TOTAL_PRS=$(cat "$TOTAL_COUNT_FILE")

# Explicitly check if PRs were found
if [ "$TOTAL_PRS" -eq 0 ]; then
    echo "No PRs with label '$LABEL' found in the last 3 months across all repositories."
    rm -rf "$TEMP_DIR"
    exit 0
fi

# Collect comments and reviews from a representative sample or all PRs
collect_comments_and_reviews

echo -e "\n============== PULL REQUEST STATISTICS ==============="

# Total number of PRs across all repositories
echo -e "\n📊 Total number of PRs with label '$LABEL': $TOTAL_PRS"

# Statistics by repository
echo -e "\n📁 PRs by repository:"
if [ -s "$REPO_STATS_FILE" ]; then
    while IFS=':' read -r repo count; do
        echo "  - $repo: $count PRs"
    done < "$REPO_STATS_FILE"
fi

# Statistics by PR creator - use the dedicated file (remove repo prefix for display)
echo -e "\n🧑‍💻 PRs created by user (across all repositories):"
if [ -s "$CREATORS_FILE" ]; then
    # Remove repo prefix and count
    cut -d':' -f2 "$CREATORS_FILE" | sort | uniq -c | sort -nr | 
    while read count user; do
        echo "  - $user: $count PRs"
    done
fi

# PR status statistics - use dedicated files
echo -e "\n🚦 PR Status:"
MERGED=$(wc -l < "$MERGED_FILE" 2>/dev/null || echo 0)
OPEN=$(grep -c "open" "$STATES_FILE" 2>/dev/null || echo 0)
CLOSED=$(grep -c "closed" "$STATES_FILE" 2>/dev/null || echo 0)
CLOSED_NOT_MERGED=$((CLOSED - MERGED))

echo "  - Merged: $MERGED"
echo "  - Open: $OPEN"
echo "  - Closed (without merge): $CLOSED_NOT_MERGED"

# Commenter statistics
ANALYZED_COUNT=$(echo "$SAMPLE_PRS" | wc -l | tr -d ' ')
if [ "$DISABLE_SAMPLING" = "true" ]; then
    COMMENT_HEADER="👥 Most active commenters (all $ANALYZED_COUNT PRs across all repositories):"
else
    COMMENT_HEADER="👥 Most active commenters (sample of $ANALYZED_COUNT PRs across all repositories):"
fi
echo -e "\n$COMMENT_HEADER"
if [ -s "$COMMENTERS_FILE" ]; then
    sort "$COMMENTERS_FILE" | uniq -c | sort -nr | head -10 |
    while read count user; do
        echo "  - $user: $count comments"
    done
else
    echo "  No comments found."
fi

# Calculate review coverage statistics
echo -e "\n👀 PR Review Coverage Statistics:"
if [ -s "$REVIEWERS_BY_PR_FILE" ]; then
    # Get unique list of PRs that were analyzed for reviews (remove repo prefix)
    REVIEWED_PRS=$(cut -d' ' -f1 "$REVIEWERS_BY_PR_FILE" | sort -u)
    REVIEWED_PR_COUNT=$(echo "$REVIEWED_PRS" | wc -l)
    
    if [ "$DISABLE_SAMPLING" = "true" ]; then
        echo "  All $REVIEWED_PR_COUNT PRs analyzed for review coverage"
    else
        echo "  Sample of $REVIEWED_PR_COUNT PRs analyzed for review coverage"
    fi
    
    # Calculate percentage of PRs reviewed by each person
    echo -e "\n  Review coverage by user (percentage of PRs reviewed):"
    
    # Count unique PRs reviewed by each person
    cut -d' ' -f2 "$REVIEWERS_BY_PR_FILE" | sort -u | 
    while read -r reviewer; do
        # Count how many unique PRs this person reviewed
        prs_reviewed=$(grep " $reviewer$" "$REVIEWERS_BY_PR_FILE" | cut -d' ' -f1 | sort -u | wc -l | tr -d ' ')
        
        # Calculate percentage
        percentage=$(echo "scale=1; ($prs_reviewed * 100) / $REVIEWED_PR_COUNT" | bc)
        
        # Add to temporary file for sorting
        echo "$reviewer $prs_reviewed $percentage" >> "${TEMP_DIR}/reviewer_percentages.txt"
    done
    
    # Display sorted by percentage (highest first)
    if [ -s "${TEMP_DIR}/reviewer_percentages.txt" ]; then
        sort -k3,3nr -k2,2nr "${TEMP_DIR}/reviewer_percentages.txt" | 
        while read -r reviewer count percentage; do
            echo "  - $reviewer: $count/$REVIEWED_PR_COUNT PRs ($percentage%)"
        done
    fi
else
    echo "  No review data found."
fi

# Average time by creator (for merged PRs) - excluding weekends
echo -e "\n⏱️ Average resolution time by creator (excluding weekends, across all repositories):"
if [ -s "$PR_TIMES_FILE" ] && [ $(wc -l < "$PR_TIMES_FILE") -gt 1 ]; then
    # Use awk to calculate average by creator
    tail -n +2 "$PR_TIMES_FILE" | awk -F ',' '
    BEGIN {
        # Initialize arrays
    }
    {
        creator = $1;
        business_hours = $6;  # Use business hours
        creator_hours[creator] += business_hours;
        creator_count[creator]++;
    }
    END {
        # Create array to store results for sorting
        i = 0;
        for (creator in creator_count) {
            avg = creator_hours[creator] / creator_count[creator];
            result[i] = creator ":" avg ":" creator_count[creator];
            i++;
        }
        
        # Bubble sort by decreasing average
        for (j = 0; j < i-1; j++) {
            for (k = j+1; k < i; k++) {
                split(result[j], a, ":");
                split(result[k], b, ":");
                if (b[2] > a[2]) {  # Compare averages
                    temp = result[j];
                    result[j] = result[k];
                    result[k] = temp;
                }
            }
        }
        
        # Display sorted results
        for (j = 0; j < i; j++) {
            split(result[j], parts, ":");
            creator = parts[1];
            avg = parts[2];
            cnt = parts[3];
            printf "  - %s: %.1f hours (%.1f days) across %d PRs\n", 
                   creator, avg, avg/24, cnt;  # Divide by 24h for days
        }
    }
    '
    
    # Display global average
    echo -e "\n  Global average time (excluding weekends):"
    tail -n +2 "$PR_TIMES_FILE" | awk -F ',' '
    {
        total += $6;  # Use business hours
        count++;
    }
    END {
        if (count > 0) {
            avg = total / count;
            printf "  %.1f hours (%.1f days) across %d PRs\n", avg, avg/24, count;  # Divide by 24h for days
        } else {
            print "  No merged PRs found.";
        }
    }'
    
    # Also display total time average for comparison
    echo -e "\n  Global average time (including weekends):"
    tail -n +2 "$PR_TIMES_FILE" | awk -F ',' '
    {
        total += $5;  # Use total hours
        count++;
    }
    END {
        if (count > 0) {
            avg = total / count;
            printf "  %.1f hours (%.1f days) across %d PRs\n", avg, avg/24, count;
        } else {
            print "  No merged PRs found.";
        }
    }'
else
    echo "  No merged PRs found."
fi

# Display summary of saved comments
echo -e "\n📝 Comments Export Summary:"
if [ -d "$COMMENTS_OUTPUT_DIR" ] && [ "$(ls -A "$COMMENTS_OUTPUT_DIR" 2>/dev/null)" ]; then
    comment_files=$(ls "$COMMENTS_OUTPUT_DIR"/*_comments.md 2>/dev/null | wc -l | tr -d ' ')
    echo "  Comments saved for $comment_files users in: $COMMENTS_OUTPUT_DIR"
    echo "  Files created:"
    ls "$COMMENTS_OUTPUT_DIR"/*_comments.md 2>/dev/null | while read -r file; do
        filename=$(basename "$file")
        username=$(echo "$filename" | sed 's/_comments\.md$//')
        comment_count=$(grep -c "^## " "$file" 2>/dev/null || echo 0)
        echo "    - $filename ($comment_count comments)"
    done
else
    echo "  No comment files were created."
fi

# Cleanup
rm -rf "$TEMP_DIR"

echo -e "\n============================================================"
echo "Analysis complete!"
