# DesertCMS

![DesertCMS logo](public/assets/site/logo.png)

DesertCMS is a static-first Perl CMS for OpenBSD, SQLite, `httpd`, and `slowcgi`.

It is built around three major ideas:

- **SubCMS hosting**: run contributor-owned sites from one master CMS.
- **OpenBSD security standards**: deploy with conservative defaults, local files, SQLite, `httpd`, `slowcgi`, `pf`, and validation tooling.
- **Adaptability**: use the same system for sites, catalogs, portfolios, docs hubs, memberships, events, directories, bookings, newsletters, donations, and more.

The formal hosted site is [desertcms.com](https://desertcms.com/).

Current release: DesertCMS v2.0. The v2 launch includes faster backend request startup, cacheable admin assets, UTF-8 form decoding for rich text edits, and release artifacts at [desertcms.com/download](https://desertcms.com/download/).

## Documentation
Start with:
- [OpenBSD Install Guide](docs/OPENBSD_74_INSTALL.md)
- [Site Owner Guide](docs/SITE_OWNER_GUIDE.md)
- [Technical Architecture](docs/TECHNICAL_ARCHITECTURE.md)
- [Managing Contributor Sites](docs/MANAGING_CONTRIBUTOR_SITES.md)
- [Content, Design, and Media](docs/CONTENT_DESIGN_AND_MEDIA.md)
  
  Public docs are also available at desertcms.com/docs.

## Quick Start
DesertCMS targets OpenBSD production servers.

### 1. Clone the repository
```sh
git clone https://github.com/KLD997/DesertCMS.git
cd DesertCMS
```

### 2. Review the install plan
Run the installer in dry-run mode first:
```sh
perl install/openbsd-install.pl --dry-run --domain example.com --public-root-name example-site
```
This prints the planned packages, users, filesystem paths, firewall rules, httpd routing, DNS/TLS checks, CMS initialization, and validation steps without changing the server.

### 3. Run the installer
```sh
doas perl install/openbsd-install.pl
```
The installer sets up the CMS app, SQLite database, OpenBSD services, generated public site files, and a temporary first-login admin account.

If you are applying the service steps manually, enable and start the DesertCMS slowcgi service:
```sh
doas rcctl enable desertcms_slowcgi
doas rcctl start desertcms_slowcgi
```

### 4. Validate production readiness
After installation:
```sh
doas perl /usr/local/www/desertcms/tools/openbsd-validate.pl --domain example.com
```

### 5. Open the admin
Visit:
```sh
https://example.com/admin/
```
On first login, DesertCMS forces the temporary admin account to choose permanent credentials.

## Major Features
### SubCMS System
DesertCMS can operate as a master CMS that provisions and manages contributor-owned SubCMS sites.
SubCMS features include:
- Contributor request forms and approval workflows
- Contributor profile setup
- Hosted contributor site provisioning
- Master Control dashboard for fleet health
- Contributor Blueprints for repeatable site defaults
- Service plans, quotas, billing state, and feature entitlements
- Owner-aware media and content records
- Governance roles and scoped access
- Federated content review before contributor content appears on the master site
- Tenant-isolation checks and safer hosted-site boundaries
This makes DesertCMS suitable for hosted site-builder networks, contributor communities, publication networks, local business directories, portfolios, archives, and managed client sites.
### OpenBSD Security Standards
DesertCMS is designed for OpenBSD first.
Security-oriented features include:
- httpd and slowcgi deployment model
- SQLite local database storage
- Conservative filesystem layout
- pf firewall guidance
- acme-client TLS guidance
- Production validation tooling
- Request body limits for admin uploads
- Admin CSRF/session protections
- Password reset and first-login hardening
- Tenant-isolation auditing
- Private source media with explicit public derivative publishing
- Root-worker pattern for privileged upgrade/provisioning tasks
- Local GeoIP support instead of runtime location API dependency
### Module System
First-party modules and workflows include:
- Pages and posts
- Media library
- Private source assets and optimized public derivatives
- Resource downloads
- Showcase / portfolio publishing
- Forms and submissions
- Docs / Resource Hub
- Map / Locations
- Shop / Catalog
- Events
- Directory listings
- Bookings / Appointments
- Membership / gated content
- Newsletter
- Donations / Fundraising
- Testimonials / Reviews
- Analytics and site health
- Theme Builder and editable theme tokens
- Navigation, redirects, sitemap, and robots publishing
