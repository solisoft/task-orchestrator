# Add E2E controller specs for features, comments, and auth

## Severity
medium — test coverage gap; the existing spec files test models but not controller endpoints

## Location
- `tests/auth_controller_spec.sl` — add E2E tests for GET /login, POST /login, GET /logout
- `tests/features_controller_spec.sl` — add E2E tests for CRUD routes (GET /features, GET /features/:id, POST /features, etc.)
- `tests/comments_controller_spec.sl` — add E2E test for POST /features/:id/comments

## Issue
The `add-feature-briefs-comments-multi-task-generation-and-user-authentication` feature shipped with test files that test model-layer behavior (User.register, Feature.create, Comment.create_comment, etc.) but don't exercise the controller endpoints via the HTTP test client. The acceptance criteria says "Controller specs for features, comments, and auth hit >90% coverage per CLAUDE.md." Coverage on the controller files is currently 4–9%.

## Proposed Fix

1. In `tests/auth_controller_spec.sl`, add E2E tests using the controller HTTP client (`get`, `post`, `res_status`, `res_body`, `assigns`) that:
   - Test `GET /login` returns 200 with the login form.
   - Test `POST /login` with valid credentials sets the session cookie and redirects.
   - Test `POST /login` with invalid credentials re-renders the form with an error.
   - Test `GET /logout` clears the session cookie and redirects to /login.

2. In `tests/features_controller_spec.sl`, add E2E tests that:
   - Test CRUD routes return expected status codes and rendered views.
   - Test `POST /features` with invalid data returns 422.
   - Test feature creation redirect flow.

3. In `tests/comments_controller_spec.sl`, add an E2E test that:
   - Test `POST /features/:id/comments` with valid data returns 200 with HTML partials.
   - Test `POST /features/:id/comments` with empty body returns 422.

4. Run `soli test --coverage --coverage-min 90.0` and verify coverage on `app/controllers/auth_controller.sl`, `app/controllers/features_controller.sl`, and `app/controllers/comments_controller.sl` meets the threshold.
