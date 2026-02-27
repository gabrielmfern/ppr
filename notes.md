1. check if already logged in
    - gh auth status
2. ensure pr creation wouldn't fail
    - `gh pr list --head "$BRANCH" --base "$BASE" --state open` to check that
      there isn't a pull request already open for the same head and base
      branches
    - `gh repo view --json defaultBranchRef -q .defaultBranchRef.name` to make
      sure there's a GitHub repo and to get the default branch name
    - `git status -sb` check that the worktree is clear
    - `git log --oneline "origin/$BASE..HEAD"` to make sure there are commits
      between base branch and HEAD branch
3. prompt for title
4. prompt for editing body
    - ask if yes or no, if yes, open $EDITOR to write the body in a temporary
      markdown file, if no, leave it empty
5. fetch the available reviewers
    - `gh api "repos/$REPO/collaborators" --paginate --jq '.[].login'`
    - `gh api "repos/$REPO/teams" --paginate --jq '.[].slug'`
6. create the pull request
    - gh pr create --base $BASE --head $BRANCH --title "" --body "" --reviewer alice,bob,my-org/platform-team
