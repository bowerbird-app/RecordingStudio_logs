# Dummy App

This Rails app exists to validate RecordingStudioLogs in a real host application.

## What It Covers

- Devise authentication with a seeded admin user
- `Current.actor` wiring for Recording Studio events
- Root workspace plus seeded folder and page recordables
- Recording Studio default layout, FlatPack assets, and Tailwind source scanning
- Mounted `RecordingStudio::Engine` route behavior inside a host app
- A home page that lists the dummy's registered logs and daily summaries
- Dummy-only `/docs/*` pages for gem-specific onboarding

## Quick Start

```bash
cd test/dummy
bundle install
bin/rails db:setup
bin/dev
```

Run the commands above from the dummy app directory, not the repository root.

Then open the app and sign in with:

- Email: `admin@admin.com`
- Password: `Password`

## Useful Routes

- `/` - dummy logs and summaries
- `/recording_studio` - redirects to `/` while the mounted Recording Studio engine stays available under that prefix for non-root routes
- `/users/sign_in` - Devise sign-in page
- `/docs/install`, `/docs/config`, `/docs/recordable_types`, `/docs/recordings_tree`, `/docs/gem_views`, `/docs/methods` - dummy-only starter pages
- `/up` - Rails health check

## Why This App Exists

Use this app to verify the logs engine in a host: partitioned site views, press-kit and press-center summaries, and an indefinite download log. If a layout, route, asset source, or Recording Studio initializer change breaks here, the gem likely needs adjustment before a host upgrade.

Authenticated pages use Recording Studio's shared default layout. Devise sign-in keeps `layouts/application`.

The home page in `app/views/home/index.html.erb` is the demo surface for registered logs. Do not turn it into a wall of documentation; the dummy docs pages exist so deeper explanations can live in focused sections.
