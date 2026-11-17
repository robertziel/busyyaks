# busyyaks repo: worker additions

- Never write an email address into a command: Claude Code's privacy hook stops it with a dialog, which busyyaks turns
  into a question on the card on every run.
- Browser QA of the dashboard signs in with the cookie `docker compose exec -T web bin/qa-cookie` prints; puppeteer
  sets it with `page.setCookie`.
- Tests, lint and CI stages run in Docker: `scripts/ci/test.sh <stage>`.
