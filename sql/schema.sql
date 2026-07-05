PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS schema_migrations (
    version INTEGER PRIMARY KEY,
    applied_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS settings (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL,
    updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS admin_users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    username TEXT NOT NULL UNIQUE,
    email TEXT NOT NULL DEFAULT '',
    role TEXT NOT NULL DEFAULT 'owner',
    password_hash TEXT NOT NULL,
    password_algo TEXT NOT NULL DEFAULT 'pbkdf2-sha256',
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    force_password_change INTEGER NOT NULL DEFAULT 0,
    disabled_at INTEGER
);

CREATE TABLE IF NOT EXISTS password_reset_tokens (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER NOT NULL REFERENCES admin_users(id) ON DELETE CASCADE,
    email TEXT NOT NULL DEFAULT '',
    token_hash TEXT NOT NULL UNIQUE,
    status TEXT NOT NULL CHECK (status IN ('pending', 'used', 'revoked', 'expired')),
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL,
    used_at INTEGER,
    ip_address TEXT NOT NULL DEFAULT ''
);

CREATE INDEX IF NOT EXISTS idx_password_reset_tokens_user_status
    ON password_reset_tokens(user_id, status, expires_at);

CREATE TABLE IF NOT EXISTS sessions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER NOT NULL REFERENCES admin_users(id) ON DELETE CASCADE,
    token_hash TEXT NOT NULL UNIQUE,
    ip_address TEXT,
    user_agent TEXT,
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL,
    last_seen_at INTEGER NOT NULL,
    revoked_at INTEGER
);

CREATE INDEX IF NOT EXISTS idx_sessions_token_hash ON sessions(token_hash);
CREATE INDEX IF NOT EXISTS idx_sessions_expires_at ON sessions(expires_at);

CREATE TABLE IF NOT EXISTS login_attempts (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    username TEXT NOT NULL,
    ip_address TEXT NOT NULL,
    attempted_at INTEGER NOT NULL,
    success INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_login_attempts_window
    ON login_attempts(username, ip_address, attempted_at);

CREATE TABLE IF NOT EXISTS audit_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    actor_user_id INTEGER REFERENCES admin_users(id) ON DELETE SET NULL,
    action TEXT NOT NULL,
    subject_type TEXT,
    subject_id INTEGER,
    ip_address TEXT,
    user_agent TEXT,
    details_json TEXT NOT NULL DEFAULT '{}',
    created_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS content_items (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    parent_id INTEGER REFERENCES content_items(id) ON DELETE SET NULL,
    type TEXT NOT NULL CHECK (type IN ('page', 'post')),
    title TEXT NOT NULL,
    slug TEXT NOT NULL UNIQUE,
    status TEXT NOT NULL CHECK (status IN ('draft', 'published', 'archived')) DEFAULT 'draft',
    excerpt TEXT NOT NULL DEFAULT '',
    meta_title TEXT NOT NULL DEFAULT '',
    meta_description TEXT NOT NULL DEFAULT '',
    canonical_url TEXT NOT NULL DEFAULT '',
    feature_image_path TEXT NOT NULL DEFAULT '',
    location_enabled INTEGER NOT NULL DEFAULT 0,
    location_lat REAL,
    location_lng REAL,
    location_label TEXT NOT NULL DEFAULT '',
    location_kind TEXT NOT NULL DEFAULT 'other' CHECK (location_kind IN ('store', 'venue', 'project', 'historical_site', 'event_location', 'service_area', 'other')),
    show_in_nav INTEGER NOT NULL DEFAULT 0,
    nav_label TEXT NOT NULL DEFAULT '',
    nav_order INTEGER NOT NULL DEFAULT 100,
    access_policy TEXT NOT NULL DEFAULT 'public' CHECK (access_policy IN ('public', 'members', 'group', 'private')),
    access_group_id INTEGER,
    body_json TEXT NOT NULL DEFAULT '[]',
    published_html TEXT NOT NULL DEFAULT '',
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    published_at INTEGER,
    deleted_at INTEGER
);

CREATE INDEX IF NOT EXISTS idx_content_items_type_status
    ON content_items(type, status);

CREATE TABLE IF NOT EXISTS content_revisions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    content_id INTEGER NOT NULL REFERENCES content_items(id) ON DELETE CASCADE,
    parent_id INTEGER,
    title TEXT NOT NULL,
    slug TEXT NOT NULL,
    status TEXT NOT NULL,
    excerpt TEXT NOT NULL DEFAULT '',
    meta_title TEXT NOT NULL DEFAULT '',
    meta_description TEXT NOT NULL DEFAULT '',
    canonical_url TEXT NOT NULL DEFAULT '',
    feature_image_path TEXT NOT NULL DEFAULT '',
    location_enabled INTEGER NOT NULL DEFAULT 0,
    location_lat REAL,
    location_lng REAL,
    location_label TEXT NOT NULL DEFAULT '',
    location_kind TEXT NOT NULL DEFAULT 'other' CHECK (location_kind IN ('store', 'venue', 'project', 'historical_site', 'event_location', 'service_area', 'other')),
    show_in_nav INTEGER NOT NULL DEFAULT 0,
    nav_label TEXT NOT NULL DEFAULT '',
    nav_order INTEGER NOT NULL DEFAULT 100,
    access_policy TEXT NOT NULL DEFAULT 'public' CHECK (access_policy IN ('public', 'members', 'group', 'private')),
    access_group_id INTEGER,
    tags_text TEXT NOT NULL DEFAULT '',
    collections_text TEXT NOT NULL DEFAULT '',
    body_json TEXT NOT NULL,
    author_user_id INTEGER REFERENCES admin_users(id) ON DELETE SET NULL,
    created_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS media_assets (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    original_name TEXT NOT NULL,
    storage_path TEXT NOT NULL,
    public_path TEXT,
    alt_text TEXT NOT NULL DEFAULT '',
    seo_title TEXT NOT NULL DEFAULT '',
    seo_description TEXT NOT NULL DEFAULT '',
    category_text TEXT NOT NULL DEFAULT '',
    tags_text TEXT NOT NULL DEFAULT '',
    collections_text TEXT NOT NULL DEFAULT '',
    owner_site_id TEXT NOT NULL DEFAULT '',
    owner_domain TEXT NOT NULL DEFAULT '',
    owner_display_name TEXT NOT NULL DEFAULT '',
    owner_email TEXT NOT NULL DEFAULT '',
    uploaded_by_user_id INTEGER REFERENCES admin_users(id) ON DELETE SET NULL,
    uploaded_by_username TEXT NOT NULL DEFAULT '',
    uploaded_by_email TEXT NOT NULL DEFAULT '',
    mime_type TEXT NOT NULL,
    width INTEGER,
    height INTEGER,
    bytes INTEGER NOT NULL,
    checksum_sha256 TEXT NOT NULL,
    derivatives_json TEXT NOT NULL DEFAULT '{}',
    created_at INTEGER NOT NULL,
    deleted_at INTEGER
);

CREATE TABLE IF NOT EXISTS media_preview_jobs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    media_id INTEGER NOT NULL REFERENCES media_assets(id) ON DELETE CASCADE,
    status TEXT NOT NULL CHECK (status IN ('queued', 'running', 'done', 'failed', 'skipped')),
    reason TEXT NOT NULL DEFAULT '',
    attempts INTEGER NOT NULL DEFAULT 0,
    last_error TEXT NOT NULL DEFAULT '',
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    completed_at INTEGER
);

CREATE INDEX IF NOT EXISTS idx_media_preview_jobs_status
    ON media_preview_jobs(status, created_at);

CREATE INDEX IF NOT EXISTS idx_media_preview_jobs_media
    ON media_preview_jobs(media_id, status);

CREATE TABLE IF NOT EXISTS shop_listings (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    media_asset_id INTEGER NOT NULL UNIQUE REFERENCES media_assets(id) ON DELETE CASCADE,
    title TEXT NOT NULL DEFAULT '',
    description TEXT NOT NULL DEFAULT '',
    listing_kind TEXT NOT NULL DEFAULT 'product' CHECK (listing_kind IN ('product', 'service', 'digital', 'portfolio_item', 'inquiry_only', 'other')),
    cta_label TEXT NOT NULL DEFAULT 'Request info',
    cta_url TEXT NOT NULL DEFAULT '',
    active INTEGER NOT NULL DEFAULT 0,
    currency TEXT NOT NULL DEFAULT 'usd',
    personal_enabled INTEGER NOT NULL DEFAULT 0,
    personal_price_cents INTEGER NOT NULL DEFAULT 0,
    commercial_enabled INTEGER NOT NULL DEFAULT 0,
    commercial_price_cents INTEGER NOT NULL DEFAULT 0,
    full_rights_enabled INTEGER NOT NULL DEFAULT 0,
    full_rights_price_cents INTEGER NOT NULL DEFAULT 0,
    full_rights_sold_at INTEGER,
    full_rights_order_id INTEGER,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_shop_listings_active
    ON shop_listings(active, updated_at);

CREATE TABLE IF NOT EXISTS shop_orders (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    listing_id INTEGER NOT NULL REFERENCES shop_listings(id) ON DELETE RESTRICT,
    media_asset_id INTEGER NOT NULL REFERENCES media_assets(id) ON DELETE RESTRICT,
    rights_type TEXT NOT NULL CHECK (rights_type IN ('personal', 'commercial', 'full')),
    status TEXT NOT NULL CHECK (status IN ('pending', 'paid', 'failed', 'canceled')) DEFAULT 'pending',
    currency TEXT NOT NULL DEFAULT 'usd',
    amount_cents INTEGER NOT NULL,
    customer_email TEXT NOT NULL DEFAULT '',
    customer_name TEXT NOT NULL DEFAULT '',
    stripe_checkout_session_id TEXT UNIQUE,
    stripe_payment_intent_id TEXT NOT NULL DEFAULT '',
    stripe_event_id TEXT NOT NULL DEFAULT '',
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    paid_at INTEGER
);

CREATE INDEX IF NOT EXISTS idx_shop_orders_status
    ON shop_orders(status, created_at);

CREATE TABLE IF NOT EXISTS shop_stripe_events (
    stripe_event_id TEXT PRIMARY KEY,
    event_type TEXT NOT NULL,
    received_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    title TEXT NOT NULL,
    slug TEXT NOT NULL UNIQUE,
    summary TEXT NOT NULL DEFAULT '',
    body TEXT NOT NULL DEFAULT '',
    status TEXT NOT NULL CHECK (status IN ('draft', 'published', 'archived')) DEFAULT 'draft',
    feature_image_path TEXT NOT NULL DEFAULT '',
    timezone TEXT NOT NULL DEFAULT 'UTC',
    all_day INTEGER NOT NULL DEFAULT 0,
    starts_at INTEGER NOT NULL,
    ends_at INTEGER,
    rrule TEXT NOT NULL DEFAULT '',
    rdate_text TEXT NOT NULL DEFAULT '',
    exdate_text TEXT NOT NULL DEFAULT '',
    location_enabled INTEGER NOT NULL DEFAULT 0,
    location_lat REAL,
    location_lng REAL,
    location_label TEXT NOT NULL DEFAULT '',
    location_kind TEXT NOT NULL DEFAULT 'event_location' CHECK (location_kind IN ('store', 'venue', 'project', 'historical_site', 'event_location', 'service_area', 'other')),
    rsvp_enabled INTEGER NOT NULL DEFAULT 0,
    rsvp_capacity INTEGER NOT NULL DEFAULT 0,
    waitlist_enabled INTEGER NOT NULL DEFAULT 1,
    ticketing_enabled INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    published_at INTEGER,
    deleted_at INTEGER
);

CREATE INDEX IF NOT EXISTS idx_events_status_time
    ON events(status, starts_at, updated_at);

CREATE TABLE IF NOT EXISTS event_occurrences (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    event_id INTEGER NOT NULL REFERENCES events(id) ON DELETE CASCADE,
    occurrence_key TEXT NOT NULL,
    starts_at INTEGER NOT NULL,
    ends_at INTEGER,
    active INTEGER NOT NULL DEFAULT 1,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    UNIQUE(event_id, occurrence_key)
);

CREATE INDEX IF NOT EXISTS idx_event_occurrences_time
    ON event_occurrences(active, starts_at);

CREATE TABLE IF NOT EXISTS event_rsvps (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    event_id INTEGER NOT NULL REFERENCES events(id) ON DELETE CASCADE,
    occurrence_id INTEGER REFERENCES event_occurrences(id) ON DELETE SET NULL,
    name TEXT NOT NULL DEFAULT '',
    email TEXT NOT NULL DEFAULT '',
    guest_count INTEGER NOT NULL DEFAULT 1,
    notes TEXT NOT NULL DEFAULT '',
    status TEXT NOT NULL CHECK (status IN ('confirmed', 'waitlist', 'canceled')) DEFAULT 'confirmed',
    ip_hash TEXT NOT NULL DEFAULT '',
    user_agent_hash TEXT NOT NULL DEFAULT '',
    notification_status TEXT NOT NULL DEFAULT '',
    notification_error TEXT NOT NULL DEFAULT '',
    notification_sent_at INTEGER,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_event_rsvps_event_status
    ON event_rsvps(event_id, occurrence_id, status, created_at);

CREATE TABLE IF NOT EXISTS event_ticket_types (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    event_id INTEGER NOT NULL REFERENCES events(id) ON DELETE CASCADE,
    name TEXT NOT NULL DEFAULT '',
    description TEXT NOT NULL DEFAULT '',
    currency TEXT NOT NULL DEFAULT 'usd',
    price_cents INTEGER NOT NULL DEFAULT 0,
    capacity INTEGER NOT NULL DEFAULT 0,
    sale_starts_at INTEGER,
    sale_ends_at INTEGER,
    active INTEGER NOT NULL DEFAULT 1,
    sort_order INTEGER NOT NULL DEFAULT 100,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_event_ticket_types_event
    ON event_ticket_types(event_id, active, sort_order);

CREATE TABLE IF NOT EXISTS event_ticket_orders (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    event_id INTEGER NOT NULL REFERENCES events(id) ON DELETE RESTRICT,
    occurrence_id INTEGER REFERENCES event_occurrences(id) ON DELETE SET NULL,
    ticket_type_id INTEGER NOT NULL REFERENCES event_ticket_types(id) ON DELETE RESTRICT,
    status TEXT NOT NULL CHECK (status IN ('pending', 'paid', 'failed', 'canceled')) DEFAULT 'pending',
    currency TEXT NOT NULL DEFAULT 'usd',
    amount_cents INTEGER NOT NULL DEFAULT 0,
    quantity INTEGER NOT NULL DEFAULT 1,
    customer_email TEXT NOT NULL DEFAULT '',
    customer_name TEXT NOT NULL DEFAULT '',
    stripe_checkout_session_id TEXT UNIQUE,
    stripe_payment_intent_id TEXT NOT NULL DEFAULT '',
    stripe_event_id TEXT NOT NULL DEFAULT '',
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    paid_at INTEGER
);

CREATE INDEX IF NOT EXISTS idx_event_ticket_orders_status
    ON event_ticket_orders(status, created_at);

CREATE TABLE IF NOT EXISTS event_stripe_events (
    stripe_event_id TEXT PRIMARY KEY,
    event_type TEXT NOT NULL,
    received_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS directory_entries (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    kind TEXT NOT NULL CHECK (kind IN ('person', 'business', 'artist', 'contributor', 'vendor', 'member', 'place', 'resource', 'organization', 'other')) DEFAULT 'other',
    title TEXT NOT NULL,
    slug TEXT NOT NULL UNIQUE,
    status TEXT NOT NULL CHECK (status IN ('draft', 'pending', 'published', 'archived')) DEFAULT 'draft',
    summary TEXT NOT NULL DEFAULT '',
    body TEXT NOT NULL DEFAULT '',
    image_path TEXT NOT NULL DEFAULT '',
    email TEXT NOT NULL DEFAULT '',
    phone TEXT NOT NULL DEFAULT '',
    website_url TEXT NOT NULL DEFAULT '',
    social_url TEXT NOT NULL DEFAULT '',
    contact_label TEXT NOT NULL DEFAULT 'Contact',
    address TEXT NOT NULL DEFAULT '',
    tags_text TEXT NOT NULL DEFAULT '',
    categories_text TEXT NOT NULL DEFAULT '',
    featured INTEGER NOT NULL DEFAULT 0,
    sort_order INTEGER NOT NULL DEFAULT 100,
    related_content_id INTEGER REFERENCES content_items(id) ON DELETE SET NULL,
    related_event_id INTEGER REFERENCES events(id) ON DELETE SET NULL,
    related_shop_listing_id INTEGER REFERENCES shop_listings(id) ON DELETE SET NULL,
    location_enabled INTEGER NOT NULL DEFAULT 0,
    location_lat REAL,
    location_lng REAL,
    location_label TEXT NOT NULL DEFAULT '',
    location_kind TEXT NOT NULL DEFAULT 'other' CHECK (location_kind IN ('store', 'venue', 'project', 'historical_site', 'event_location', 'service_area', 'other')),
    source TEXT NOT NULL DEFAULT 'manual' CHECK (source IN ('manual', 'public_submission', 'import')),
    submitter_name TEXT NOT NULL DEFAULT '',
    submitter_email TEXT NOT NULL DEFAULT '',
    submission_note TEXT NOT NULL DEFAULT '',
    ip_hash TEXT NOT NULL DEFAULT '',
    user_agent_hash TEXT NOT NULL DEFAULT '',
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    published_at INTEGER,
    deleted_at INTEGER
);

CREATE INDEX IF NOT EXISTS idx_directory_entries_status_kind
    ON directory_entries(status, kind, featured, sort_order, title);

CREATE INDEX IF NOT EXISTS idx_directory_entries_location
    ON directory_entries(status, location_enabled, location_lat, location_lng);

CREATE TABLE IF NOT EXISTS booking_services (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    service_kind TEXT NOT NULL CHECK (service_kind IN ('appointment', 'consultation', 'project', 'rental', 'venue', 'creative_session', 'other')) DEFAULT 'appointment',
    title TEXT NOT NULL,
    slug TEXT NOT NULL UNIQUE,
    status TEXT NOT NULL CHECK (status IN ('draft', 'published', 'archived')) DEFAULT 'draft',
    summary TEXT NOT NULL DEFAULT '',
    body TEXT NOT NULL DEFAULT '',
    image_path TEXT NOT NULL DEFAULT '',
    availability_text TEXT NOT NULL DEFAULT '',
    duration_minutes INTEGER NOT NULL DEFAULT 0,
    price_note TEXT NOT NULL DEFAULT '',
    deposit_enabled INTEGER NOT NULL DEFAULT 0,
    deposit_label TEXT NOT NULL DEFAULT 'Deposit',
    deposit_amount_cents INTEGER NOT NULL DEFAULT 0,
    deposit_currency TEXT NOT NULL DEFAULT 'usd',
    featured INTEGER NOT NULL DEFAULT 0,
    sort_order INTEGER NOT NULL DEFAULT 100,
    location_enabled INTEGER NOT NULL DEFAULT 0,
    location_lat REAL,
    location_lng REAL,
    location_label TEXT NOT NULL DEFAULT '',
    location_kind TEXT NOT NULL DEFAULT 'service_area' CHECK (location_kind IN ('store', 'venue', 'project', 'historical_site', 'event_location', 'service_area', 'other')),
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    published_at INTEGER,
    deleted_at INTEGER
);

CREATE INDEX IF NOT EXISTS idx_booking_services_status_kind
    ON booking_services(status, service_kind, featured, sort_order, title);

CREATE INDEX IF NOT EXISTS idx_booking_services_location
    ON booking_services(status, location_enabled, location_lat, location_lng);

CREATE TABLE IF NOT EXISTS booking_requests (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    service_id INTEGER NOT NULL REFERENCES booking_services(id) ON DELETE RESTRICT,
    status TEXT NOT NULL CHECK (status IN ('new', 'reviewing', 'accepted', 'declined', 'canceled', 'completed')) DEFAULT 'new',
    name TEXT NOT NULL DEFAULT '',
    email TEXT NOT NULL DEFAULT '',
    phone TEXT NOT NULL DEFAULT '',
    organization TEXT NOT NULL DEFAULT '',
    requested_date TEXT NOT NULL DEFAULT '',
    requested_time TEXT NOT NULL DEFAULT '',
    preferred_window TEXT NOT NULL DEFAULT '',
    party_size INTEGER,
    budget TEXT NOT NULL DEFAULT '',
    notes TEXT NOT NULL DEFAULT '',
    deposit_required INTEGER NOT NULL DEFAULT 0,
    deposit_status TEXT NOT NULL CHECK (deposit_status IN ('none', 'pending', 'paid', 'failed', 'canceled')) DEFAULT 'none',
    deposit_payment_id INTEGER,
    ip_hash TEXT NOT NULL DEFAULT '',
    user_agent_hash TEXT NOT NULL DEFAULT '',
    notification_status TEXT NOT NULL DEFAULT '',
    notification_error TEXT NOT NULL DEFAULT '',
    notification_sent_at INTEGER,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_booking_requests_service_status
    ON booking_requests(service_id, status, created_at);

CREATE TABLE IF NOT EXISTS booking_payments (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    service_id INTEGER NOT NULL REFERENCES booking_services(id) ON DELETE RESTRICT,
    request_id INTEGER REFERENCES booking_requests(id) ON DELETE SET NULL,
    status TEXT NOT NULL CHECK (status IN ('pending', 'paid', 'failed', 'canceled')) DEFAULT 'pending',
    currency TEXT NOT NULL DEFAULT 'usd',
    amount_cents INTEGER NOT NULL DEFAULT 0,
    customer_email TEXT NOT NULL DEFAULT '',
    customer_name TEXT NOT NULL DEFAULT '',
    stripe_checkout_session_id TEXT UNIQUE,
    stripe_payment_intent_id TEXT NOT NULL DEFAULT '',
    stripe_event_id TEXT NOT NULL DEFAULT '',
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    paid_at INTEGER
);

CREATE INDEX IF NOT EXISTS idx_booking_payments_status
    ON booking_payments(status, created_at);

CREATE TABLE IF NOT EXISTS booking_stripe_events (
    stripe_event_id TEXT PRIMARY KEY,
    event_type TEXT NOT NULL,
    received_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS member_accounts (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    email TEXT NOT NULL UNIQUE,
    display_name TEXT NOT NULL DEFAULT '',
    password_hash TEXT NOT NULL DEFAULT '',
    password_algo TEXT NOT NULL DEFAULT 'pbkdf2-sha256',
    status TEXT NOT NULL CHECK (status IN ('pending', 'invited', 'active', 'disabled')) DEFAULT 'active',
    signup_source TEXT NOT NULL DEFAULT '',
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    confirmed_at INTEGER,
    disabled_at INTEGER,
    last_login_at INTEGER
);

CREATE INDEX IF NOT EXISTS idx_member_accounts_status
    ON member_accounts(status, email);

CREATE TABLE IF NOT EXISTS member_groups (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL UNIQUE,
    slug TEXT NOT NULL UNIQUE,
    description TEXT NOT NULL DEFAULT '',
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS member_group_members (
    member_id INTEGER NOT NULL REFERENCES member_accounts(id) ON DELETE CASCADE,
    group_id INTEGER NOT NULL REFERENCES member_groups(id) ON DELETE CASCADE,
    created_at INTEGER NOT NULL,
    PRIMARY KEY (member_id, group_id)
);

CREATE INDEX IF NOT EXISTS idx_member_group_members_group
    ON member_group_members(group_id, member_id);

CREATE TABLE IF NOT EXISTS member_invites (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    email TEXT NOT NULL,
    display_name TEXT NOT NULL DEFAULT '',
    group_id INTEGER REFERENCES member_groups(id) ON DELETE SET NULL,
    token_hash TEXT NOT NULL UNIQUE,
    status TEXT NOT NULL CHECK (status IN ('pending', 'accepted', 'revoked', 'expired')) DEFAULT 'pending',
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL,
    accepted_at INTEGER,
    ip_address TEXT NOT NULL DEFAULT ''
);

CREATE INDEX IF NOT EXISTS idx_member_invites_email_status
    ON member_invites(email, status, expires_at);

CREATE TABLE IF NOT EXISTS member_sessions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    member_id INTEGER NOT NULL REFERENCES member_accounts(id) ON DELETE CASCADE,
    token_hash TEXT NOT NULL UNIQUE,
    ip_address TEXT NOT NULL DEFAULT '',
    user_agent TEXT NOT NULL DEFAULT '',
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL,
    last_seen_at INTEGER NOT NULL,
    revoked_at INTEGER
);

CREATE INDEX IF NOT EXISTS idx_member_sessions_token_hash
    ON member_sessions(token_hash);

CREATE INDEX IF NOT EXISTS idx_member_sessions_expires
    ON member_sessions(expires_at, revoked_at);

CREATE TABLE IF NOT EXISTS member_password_reset_tokens (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    member_id INTEGER NOT NULL REFERENCES member_accounts(id) ON DELETE CASCADE,
    email TEXT NOT NULL DEFAULT '',
    token_hash TEXT NOT NULL UNIQUE,
    status TEXT NOT NULL CHECK (status IN ('pending', 'used', 'revoked', 'expired')) DEFAULT 'pending',
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL,
    used_at INTEGER,
    ip_address TEXT NOT NULL DEFAULT ''
);

CREATE INDEX IF NOT EXISTS idx_member_password_reset_tokens_member_status
    ON member_password_reset_tokens(member_id, status, expires_at);

CREATE TABLE IF NOT EXISTS membership_resources (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    title TEXT NOT NULL,
    slug TEXT NOT NULL UNIQUE,
    summary TEXT NOT NULL DEFAULT '',
    body TEXT NOT NULL DEFAULT '',
    media_asset_id INTEGER REFERENCES media_assets(id) ON DELETE SET NULL,
    collection_name TEXT NOT NULL DEFAULT '',
    access_policy TEXT NOT NULL CHECK (access_policy IN ('members', 'group', 'private')) DEFAULT 'members',
    access_group_id INTEGER REFERENCES member_groups(id) ON DELETE SET NULL,
    status TEXT NOT NULL CHECK (status IN ('draft', 'published', 'archived')) DEFAULT 'draft',
    direct_download INTEGER NOT NULL DEFAULT 1,
    sort_order INTEGER NOT NULL DEFAULT 100,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    published_at INTEGER
);

CREATE INDEX IF NOT EXISTS idx_membership_resources_status
    ON membership_resources(status, access_policy, sort_order, title);

CREATE TABLE IF NOT EXISTS membership_payments (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    member_id INTEGER REFERENCES member_accounts(id) ON DELETE SET NULL,
    resource_id INTEGER REFERENCES membership_resources(id) ON DELETE SET NULL,
    status TEXT NOT NULL CHECK (status IN ('pending', 'paid', 'failed', 'canceled', 'refunded')) DEFAULT 'pending',
    amount_cents INTEGER NOT NULL DEFAULT 0,
    currency TEXT NOT NULL DEFAULT 'usd',
    stripe_checkout_session_id TEXT NOT NULL DEFAULT '',
    stripe_payment_intent_id TEXT NOT NULL DEFAULT '',
    stripe_customer_id TEXT NOT NULL DEFAULT '',
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    paid_at INTEGER
);

CREATE INDEX IF NOT EXISTS idx_membership_payments_status
    ON membership_payments(status, created_at);

CREATE TABLE IF NOT EXISTS membership_stripe_events (
    stripe_event_id TEXT PRIMARY KEY,
    event_type TEXT NOT NULL,
    received_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS newsletter_subscribers (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    email TEXT NOT NULL UNIQUE,
    display_name TEXT NOT NULL DEFAULT '',
    status TEXT NOT NULL CHECK (status IN ('active', 'unsubscribed', 'bounced', 'complained', 'archived')) DEFAULT 'active',
    tags_text TEXT NOT NULL DEFAULT '',
    segments_text TEXT NOT NULL DEFAULT '',
    consent_text TEXT NOT NULL DEFAULT '',
    source TEXT NOT NULL DEFAULT 'public_signup' CHECK (source IN ('public_signup', 'manual', 'import')),
    unsubscribe_token TEXT NOT NULL DEFAULT '',
    ip_hash TEXT NOT NULL DEFAULT '',
    user_agent_hash TEXT NOT NULL DEFAULT '',
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    confirmed_at INTEGER,
    unsubscribed_at INTEGER
);

CREATE INDEX IF NOT EXISTS idx_newsletter_subscribers_status
    ON newsletter_subscribers(status, email);

CREATE TABLE IF NOT EXISTS newsletter_announcements (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    title TEXT NOT NULL,
    subject TEXT NOT NULL DEFAULT '',
    slug TEXT NOT NULL UNIQUE,
    status TEXT NOT NULL CHECK (status IN ('draft', 'ready', 'sent', 'archived')) DEFAULT 'draft',
    manual_body TEXT NOT NULL DEFAULT '',
    digest_sources_json TEXT NOT NULL DEFAULT '{}',
    preview_text TEXT NOT NULL DEFAULT '',
    preview_html TEXT NOT NULL DEFAULT '',
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    sent_at INTEGER
);

CREATE INDEX IF NOT EXISTS idx_newsletter_announcements_status
    ON newsletter_announcements(status, updated_at);

CREATE TABLE IF NOT EXISTS newsletter_send_history (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    announcement_id INTEGER REFERENCES newsletter_announcements(id) ON DELETE SET NULL,
    subscriber_id INTEGER REFERENCES newsletter_subscribers(id) ON DELETE SET NULL,
    email TEXT NOT NULL DEFAULT '',
    subject TEXT NOT NULL DEFAULT '',
    status TEXT NOT NULL CHECK (status IN ('sent', 'skipped', 'failed')) DEFAULT 'skipped',
    error TEXT NOT NULL DEFAULT '',
    postmark_message_id TEXT NOT NULL DEFAULT '',
    created_at INTEGER NOT NULL,
    sent_at INTEGER
);

CREATE INDEX IF NOT EXISTS idx_newsletter_send_history_time
    ON newsletter_send_history(created_at, status);

CREATE TABLE IF NOT EXISTS donation_campaigns (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    title TEXT NOT NULL,
    slug TEXT NOT NULL UNIQUE,
    status TEXT NOT NULL CHECK (status IN ('draft', 'published', 'archived')) DEFAULT 'draft',
    summary TEXT NOT NULL DEFAULT '',
    body TEXT NOT NULL DEFAULT '',
    image_path TEXT NOT NULL DEFAULT '',
    goal_amount_cents INTEGER NOT NULL DEFAULT 0,
    currency TEXT NOT NULL DEFAULT 'usd',
    suggested_amounts_text TEXT NOT NULL DEFAULT '',
    allow_custom_amount INTEGER NOT NULL DEFAULT 1,
    donor_message_enabled INTEGER NOT NULL DEFAULT 1,
    show_goal INTEGER NOT NULL DEFAULT 1,
    featured INTEGER NOT NULL DEFAULT 0,
    sort_order INTEGER NOT NULL DEFAULT 100,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    published_at INTEGER,
    archived_at INTEGER
);

CREATE INDEX IF NOT EXISTS idx_donation_campaigns_status
    ON donation_campaigns(status, featured, sort_order, title);

CREATE TABLE IF NOT EXISTS donations (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    campaign_id INTEGER NOT NULL REFERENCES donation_campaigns(id) ON DELETE RESTRICT,
    status TEXT NOT NULL CHECK (status IN ('pending', 'paid', 'failed', 'canceled', 'refunded')) DEFAULT 'pending',
    amount_cents INTEGER NOT NULL DEFAULT 0,
    currency TEXT NOT NULL DEFAULT 'usd',
    donor_email TEXT NOT NULL DEFAULT '',
    donor_name TEXT NOT NULL DEFAULT '',
    donor_message TEXT NOT NULL DEFAULT '',
    anonymous INTEGER NOT NULL DEFAULT 0,
    platform_fee_cents INTEGER NOT NULL DEFAULT 0,
    stripe_checkout_session_id TEXT UNIQUE,
    stripe_payment_intent_id TEXT NOT NULL DEFAULT '',
    stripe_event_id TEXT NOT NULL DEFAULT '',
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    paid_at INTEGER
);

CREATE INDEX IF NOT EXISTS idx_donations_campaign_status
    ON donations(campaign_id, status, created_at);

CREATE TABLE IF NOT EXISTS donation_stripe_events (
    stripe_event_id TEXT PRIMARY KEY,
    event_type TEXT NOT NULL,
    received_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS testimonials (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    author_name TEXT NOT NULL,
    author_title TEXT NOT NULL DEFAULT '',
    organization TEXT NOT NULL DEFAULT '',
    slug TEXT NOT NULL UNIQUE,
    status TEXT NOT NULL CHECK (status IN ('draft', 'pending', 'published', 'rejected', 'archived')) DEFAULT 'draft',
    quote TEXT NOT NULL DEFAULT '',
    body TEXT NOT NULL DEFAULT '',
    rating INTEGER CHECK (rating IS NULL OR (rating >= 1 AND rating <= 5)),
    source_type TEXT NOT NULL CHECK (source_type IN ('manual', 'public_submission', 'client', 'customer', 'member', 'event', 'booking', 'other')) DEFAULT 'manual',
    related_directory_entry_id INTEGER REFERENCES directory_entries(id) ON DELETE SET NULL,
    related_booking_service_id INTEGER REFERENCES booking_services(id) ON DELETE SET NULL,
    image_path TEXT NOT NULL DEFAULT '',
    featured INTEGER NOT NULL DEFAULT 0,
    sort_order INTEGER NOT NULL DEFAULT 100,
    submitter_email TEXT NOT NULL DEFAULT '',
    submission_note TEXT NOT NULL DEFAULT '',
    ip_hash TEXT NOT NULL DEFAULT '',
    user_agent_hash TEXT NOT NULL DEFAULT '',
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    published_at INTEGER,
    rejected_at INTEGER,
    archived_at INTEGER
);

CREATE INDEX IF NOT EXISTS idx_testimonials_status
    ON testimonials(status, featured, sort_order, updated_at);

CREATE TABLE IF NOT EXISTS tags (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    slug TEXT NOT NULL UNIQUE,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS content_tags (
    content_id INTEGER NOT NULL REFERENCES content_items(id) ON DELETE CASCADE,
    tag_id INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
    PRIMARY KEY (content_id, tag_id)
);

CREATE TABLE IF NOT EXISTS collections (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    slug TEXT NOT NULL UNIQUE,
    description TEXT NOT NULL DEFAULT '',
    sort_order INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS content_collections (
    content_id INTEGER NOT NULL REFERENCES content_items(id) ON DELETE CASCADE,
    collection_id INTEGER NOT NULL REFERENCES collections(id) ON DELETE CASCADE,
    PRIMARY KEY (content_id, collection_id)
);

CREATE TABLE IF NOT EXISTS page_templates (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    slug TEXT NOT NULL UNIQUE,
    description TEXT NOT NULL DEFAULT '',
    body_json TEXT NOT NULL DEFAULT '[]',
    system_default INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    deleted_at INTEGER
);

CREATE TABLE IF NOT EXISTS builder_sections (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    slug TEXT NOT NULL UNIQUE,
    description TEXT NOT NULL DEFAULT '',
    body_json TEXT NOT NULL DEFAULT '[]',
    system_default INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    deleted_at INTEGER
);

CREATE TABLE IF NOT EXISTS navigation_items (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    label TEXT NOT NULL,
    url TEXT NOT NULL,
    sort_order INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS redirects (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    source_path TEXT NOT NULL UNIQUE,
    target_url TEXT NOT NULL,
    status_code INTEGER NOT NULL DEFAULT 301 CHECK (status_code IN (301, 302)),
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS analytics_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    path TEXT NOT NULL,
    ip_hash TEXT NOT NULL,
    ip_address TEXT NOT NULL DEFAULT '',
    user_agent_hash TEXT NOT NULL DEFAULT '',
    referrer TEXT NOT NULL DEFAULT '',
    country_code TEXT NOT NULL DEFAULT '',
    country TEXT NOT NULL DEFAULT '',
    region TEXT NOT NULL DEFAULT '',
    city TEXT NOT NULL DEFAULT '',
    occurred_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_analytics_events_occurred_at
    ON analytics_events(occurred_at);

CREATE INDEX IF NOT EXISTS idx_analytics_events_path_time
    ON analytics_events(path, occurred_at);

CREATE INDEX IF NOT EXISTS idx_analytics_events_ip_time
    ON analytics_events(ip_hash, occurred_at);

CREATE TABLE IF NOT EXISTS comments (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    content_id INTEGER NOT NULL REFERENCES content_items(id) ON DELETE CASCADE,
    parent_id INTEGER REFERENCES comments(id) ON DELETE CASCADE,
    author_name TEXT NOT NULL,
    body TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'visible' CHECK (status IN ('visible', 'pending', 'deleted')),
    commenter_token_hash TEXT NOT NULL DEFAULT '',
    ip_hash TEXT NOT NULL DEFAULT '',
    user_agent_hash TEXT NOT NULL DEFAULT '',
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_comments_content_status_time
    ON comments(content_id, status, created_at);

CREATE INDEX IF NOT EXISTS idx_comments_parent
    ON comments(parent_id);

CREATE INDEX IF NOT EXISTS idx_comments_token_time
    ON comments(commenter_token_hash, created_at);

CREATE TABLE IF NOT EXISTS post_ratings (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    content_id INTEGER NOT NULL REFERENCES content_items(id) ON DELETE CASCADE,
    ip_hash TEXT NOT NULL,
    rating INTEGER NOT NULL CHECK (rating BETWEEN 1 AND 5),
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    UNIQUE(content_id, ip_hash)
);

CREATE INDEX IF NOT EXISTS idx_post_ratings_content
    ON post_ratings(content_id, updated_at);

CREATE TABLE IF NOT EXISTS form_submissions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    form_key TEXT NOT NULL DEFAULT 'contact',
    name TEXT NOT NULL DEFAULT '',
    email TEXT NOT NULL DEFAULT '',
    phone TEXT NOT NULL DEFAULT '',
    organization TEXT NOT NULL DEFAULT '',
    subject TEXT NOT NULL DEFAULT '',
    message TEXT NOT NULL,
    preferred_date TEXT NOT NULL DEFAULT '',
    event_date TEXT NOT NULL DEFAULT '',
    guest_count INTEGER,
    budget TEXT NOT NULL DEFAULT '',
    attachment_json TEXT NOT NULL DEFAULT '[]',
    status TEXT NOT NULL DEFAULT 'new' CHECK (status IN ('new', 'read', 'archived')),
    ip_hash TEXT NOT NULL DEFAULT '',
    user_agent_hash TEXT NOT NULL DEFAULT '',
    notification_status TEXT NOT NULL DEFAULT '',
    notification_error TEXT NOT NULL DEFAULT '',
    notification_sent_at INTEGER,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_form_submissions_status_time
    ON form_submissions(status, created_at);

CREATE TABLE IF NOT EXISTS analytics_geoip_ranges (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ip_version INTEGER NOT NULL CHECK (ip_version IN (4, 6)),
    start_ip BLOB NOT NULL,
    end_ip BLOB NOT NULL,
    country_code TEXT NOT NULL DEFAULT '',
    country TEXT NOT NULL DEFAULT '',
    region TEXT NOT NULL DEFAULT '',
    city TEXT NOT NULL DEFAULT '',
    source TEXT NOT NULL DEFAULT '',
    imported_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_analytics_geoip_range
    ON analytics_geoip_ranges(ip_version, start_ip);

CREATE TABLE IF NOT EXISTS analytics_geoip_meta (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL DEFAULT '',
    updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS themes (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL UNIQUE,
    active INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS theme_files (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    theme_id INTEGER NOT NULL REFERENCES themes(id) ON DELETE CASCADE,
    path TEXT NOT NULL,
    body TEXT NOT NULL,
    updated_at INTEGER NOT NULL,
    UNIQUE(theme_id, path)
);

CREATE TABLE IF NOT EXISTS backups (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    filename TEXT NOT NULL UNIQUE,
    manifest_json TEXT NOT NULL,
    created_by_user_id INTEGER REFERENCES admin_users(id) ON DELETE SET NULL,
    created_at INTEGER NOT NULL,
    restored_at INTEGER
);

CREATE TABLE IF NOT EXISTS contributor_blueprints (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL UNIQUE,
    slug TEXT NOT NULL UNIQUE,
    description TEXT NOT NULL DEFAULT '',
    category TEXT NOT NULL DEFAULT 'photographer',
    module_map_enabled INTEGER NOT NULL DEFAULT 1,
    module_shop_enabled INTEGER NOT NULL DEFAULT 0,
    module_gallery_enabled INTEGER NOT NULL DEFAULT 1,
    module_forms_enabled INTEGER NOT NULL DEFAULT 0,
    module_contributor_requests_enabled INTEGER NOT NULL DEFAULT 0,
    module_docs_enabled INTEGER NOT NULL DEFAULT 0,
    module_directory_enabled INTEGER NOT NULL DEFAULT 0,
    module_bookings_enabled INTEGER NOT NULL DEFAULT 0,
    module_membership_enabled INTEGER NOT NULL DEFAULT 0,
    module_newsletter_enabled INTEGER NOT NULL DEFAULT 0,
    module_donations_enabled INTEGER NOT NULL DEFAULT 0,
    module_testimonials_enabled INTEGER NOT NULL DEFAULT 0,
    theme_default_mode TEXT NOT NULL DEFAULT 'light' CHECK (theme_default_mode IN ('light', 'dark')),
    theme_light_preset TEXT NOT NULL DEFAULT 'light-archive',
    theme_dark_preset TEXT NOT NULL DEFAULT 'dark-archive',
    shop_enabled INTEGER NOT NULL DEFAULT 0,
    media_quota_mb INTEGER NOT NULL DEFAULT 512,
    post_quota INTEGER NOT NULL DEFAULT 100,
    page_quota INTEGER NOT NULL DEFAULT 20,
    features_json TEXT NOT NULL DEFAULT '{}',
    allow_master_gallery INTEGER NOT NULL DEFAULT 1,
    allow_master_posts INTEGER NOT NULL DEFAULT 1,
    site_meta_title TEXT NOT NULL DEFAULT '',
    site_meta_description TEXT NOT NULL DEFAULT '',
    default_pages_json TEXT NOT NULL DEFAULT '[]',
    is_default INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_contributor_blueprints_default
    ON contributor_blueprints(is_default, name);

CREATE TABLE IF NOT EXISTS service_plans (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL UNIQUE,
    slug TEXT NOT NULL UNIQUE,
    description TEXT NOT NULL DEFAULT '',
    blueprint_id INTEGER REFERENCES contributor_blueprints(id) ON DELETE SET NULL,
    monthly_price_cents INTEGER NOT NULL DEFAULT 0,
    currency TEXT NOT NULL DEFAULT 'usd',
    stripe_price_id TEXT NOT NULL DEFAULT '',
    media_quota_mb INTEGER NOT NULL DEFAULT 512,
    media_upload_limit_mb INTEGER NOT NULL DEFAULT 64,
    post_quota INTEGER NOT NULL DEFAULT 100,
    page_quota INTEGER NOT NULL DEFAULT 20,
    features_json TEXT NOT NULL DEFAULT '{}',
    allow_master_gallery INTEGER NOT NULL DEFAULT 1,
    allow_master_posts INTEGER NOT NULL DEFAULT 1,
    allow_postmark_sender_override INTEGER NOT NULL DEFAULT 0,
    allow_stripe_connect INTEGER NOT NULL DEFAULT 0,
    allow_indexing_override INTEGER NOT NULL DEFAULT 0,
    stripe_platform_fee_bps INTEGER NOT NULL DEFAULT 0,
    is_default INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_service_plans_default
    ON service_plans(is_default, name);

CREATE TABLE IF NOT EXISTS service_plan_checkout_sessions (
    stripe_checkout_session_id TEXT PRIMARY KEY,
    site_id TEXT NOT NULL,
    plan_id INTEGER NOT NULL REFERENCES service_plans(id) ON DELETE CASCADE,
    stripe_price_id TEXT NOT NULL DEFAULT '',
    stripe_customer_id TEXT NOT NULL DEFAULT '',
    amount_cents INTEGER NOT NULL DEFAULT 0,
    currency TEXT NOT NULL DEFAULT 'usd',
    status TEXT NOT NULL CHECK (status IN ('pending', 'completed', 'ignored')) DEFAULT 'pending',
    created_at INTEGER NOT NULL,
    completed_at INTEGER
);

CREATE INDEX IF NOT EXISTS idx_service_plan_checkout_sessions_site
    ON service_plan_checkout_sessions(site_id, status, created_at);

CREATE TABLE IF NOT EXISTS contributor_sites (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    site_id TEXT NOT NULL UNIQUE,
    domain TEXT NOT NULL UNIQUE,
    display_name TEXT NOT NULL,
    owner_first_name TEXT NOT NULL DEFAULT '',
    owner_last_initial TEXT NOT NULL DEFAULT '',
    owner_email TEXT NOT NULL DEFAULT '',
    blueprint_id INTEGER REFERENCES contributor_blueprints(id) ON DELETE SET NULL,
    blueprint_snapshot_json TEXT NOT NULL DEFAULT '{}',
    media_quota_mb INTEGER NOT NULL DEFAULT 0,
    media_upload_limit_mb INTEGER NOT NULL DEFAULT 64,
    post_quota INTEGER NOT NULL DEFAULT 0,
    page_quota INTEGER NOT NULL DEFAULT 0,
    allow_master_gallery INTEGER NOT NULL DEFAULT 1,
    allow_master_posts INTEGER NOT NULL DEFAULT 1,
    service_plan_id INTEGER REFERENCES service_plans(id) ON DELETE SET NULL,
    billing_status TEXT NOT NULL DEFAULT 'comped' CHECK (billing_status IN ('trialing', 'active', 'past_due', 'canceled', 'comped')),
    billing_email TEXT NOT NULL DEFAULT '',
    stripe_customer_id TEXT NOT NULL DEFAULT '',
    stripe_subscription_id TEXT NOT NULL DEFAULT '',
    billing_started_at INTEGER,
    billing_current_period_end INTEGER,
    stripe_connect_account_id TEXT NOT NULL DEFAULT '',
    stripe_connect_onboarding_status TEXT NOT NULL DEFAULT '',
    stripe_connect_charges_enabled INTEGER NOT NULL DEFAULT 0,
    stripe_connect_payouts_enabled INTEGER NOT NULL DEFAULT 0,
    status TEXT NOT NULL CHECK (status IN ('pending_provision', 'active', 'disabled', 'destroy_pending', 'destroyed')),
    config_path TEXT NOT NULL DEFAULT '',
    data_dir TEXT NOT NULL DEFAULT '',
    public_root TEXT NOT NULL DEFAULT '',
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    provisioned_at INTEGER,
    disabled_at INTEGER,
    destroyed_at INTEGER
);

CREATE INDEX IF NOT EXISTS idx_contributor_sites_status
    ON contributor_sites(status);

CREATE TABLE IF NOT EXISTS archived_sites (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    site_id TEXT NOT NULL,
    domain TEXT NOT NULL,
    display_name TEXT NOT NULL DEFAULT '',
    owner_first_name TEXT NOT NULL DEFAULT '',
    owner_last_initial TEXT NOT NULL DEFAULT '',
    owner_email TEXT NOT NULL DEFAULT '',
    archive_path TEXT NOT NULL UNIQUE,
    archive_filename TEXT NOT NULL,
    archive_bytes INTEGER NOT NULL DEFAULT 0,
    details_json TEXT NOT NULL DEFAULT '{}',
    archived_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_archived_sites_archived_at
    ON archived_sites(archived_at DESC);

CREATE TABLE IF NOT EXISTS federated_content_reviews (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    source_site_id TEXT NOT NULL,
    source_domain TEXT NOT NULL,
    source_type TEXT NOT NULL CHECK (source_type IN ('media', 'post')),
    source_id INTEGER NOT NULL,
    source_slug TEXT NOT NULL DEFAULT '',
    source_url TEXT NOT NULL DEFAULT '',
    image_url TEXT NOT NULL DEFAULT '',
    title TEXT NOT NULL DEFAULT '',
    summary TEXT NOT NULL DEFAULT '',
    status TEXT NOT NULL CHECK (status IN ('pending', 'approved', 'rejected')) DEFAULT 'pending',
    first_seen_at INTEGER NOT NULL,
    last_seen_at INTEGER NOT NULL,
    source_updated_at INTEGER,
    source_missing_at INTEGER,
    reviewed_at INTEGER,
    reviewed_by_user_id INTEGER REFERENCES admin_users(id) ON DELETE SET NULL,
    review_note TEXT NOT NULL DEFAULT '',
    details_json TEXT NOT NULL DEFAULT '{}',
    UNIQUE(source_site_id, source_type, source_id)
);

CREATE INDEX IF NOT EXISTS idx_federated_content_reviews_status
    ON federated_content_reviews(status, source_type, last_seen_at);

CREATE TABLE IF NOT EXISTS contributor_invites (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    email TEXT NOT NULL,
    token_hash TEXT NOT NULL UNIQUE,
    status TEXT NOT NULL CHECK (status IN ('pending', 'accepted', 'revoked', 'expired')),
    message TEXT NOT NULL DEFAULT '',
    site_id TEXT NOT NULL DEFAULT '',
    domain TEXT NOT NULL DEFAULT '',
    blueprint_id INTEGER REFERENCES contributor_blueprints(id) ON DELETE SET NULL,
    created_by_user_id INTEGER REFERENCES admin_users(id) ON DELETE SET NULL,
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL,
    accepted_at INTEGER,
    revoked_at INTEGER
);

CREATE INDEX IF NOT EXISTS idx_contributor_invites_status
    ON contributor_invites(status, expires_at);

CREATE TABLE IF NOT EXISTS contributor_requests (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    first_name TEXT NOT NULL DEFAULT '',
    last_name TEXT NOT NULL DEFAULT '',
    last_initial TEXT NOT NULL DEFAULT '',
    email TEXT NOT NULL,
    phone TEXT NOT NULL DEFAULT '',
    age INTEGER NOT NULL,
    -- Legacy contributor request field retained for existing databases. Current forms do not collect it.
    gender TEXT NOT NULL DEFAULT '',
    application_text TEXT NOT NULL DEFAULT '',
    application_showcase_json TEXT NOT NULL DEFAULT '[]',
    bio TEXT NOT NULL DEFAULT '',
    status TEXT NOT NULL CHECK (status IN ('new', 'reviewing', 'approved', 'denied')),
    profile_photo_path TEXT NOT NULL DEFAULT '',
    profile_photo_mime TEXT NOT NULL DEFAULT '',
    public_profile_image_path TEXT NOT NULL DEFAULT '',
    showcase_json TEXT NOT NULL DEFAULT '[]',
    site_id TEXT NOT NULL DEFAULT '',
    domain TEXT NOT NULL DEFAULT '',
    blueprint_id INTEGER REFERENCES contributor_blueprints(id) ON DELETE SET NULL,
    review_note TEXT NOT NULL DEFAULT '',
    profile_token_hash TEXT NOT NULL DEFAULT '',
    profile_token_expires_at INTEGER,
    profile_completed_at INTEGER,
    ip_hash TEXT NOT NULL DEFAULT '',
    user_agent_hash TEXT NOT NULL DEFAULT '',
    submitted_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    reviewed_at INTEGER,
    approved_at INTEGER,
    denied_at INTEGER
);

CREATE INDEX IF NOT EXISTS idx_contributor_requests_status
    ON contributor_requests(status, submitted_at);

CREATE INDEX IF NOT EXISTS idx_contributor_requests_email_time
    ON contributor_requests(email COLLATE NOCASE, submitted_at);

CREATE TABLE IF NOT EXISTS site_provisioning_queue (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    site_id TEXT NOT NULL,
    action TEXT NOT NULL CHECK (action IN ('create', 'enable', 'disable', 'destroy')),
    status TEXT NOT NULL CHECK (status IN ('queued', 'running', 'done', 'failed')),
    details_json TEXT NOT NULL DEFAULT '{}',
    created_by_user_id INTEGER REFERENCES admin_users(id) ON DELETE SET NULL,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    completed_at INTEGER,
    error_text TEXT NOT NULL DEFAULT ''
);

CREATE INDEX IF NOT EXISTS idx_site_provisioning_queue_status
    ON site_provisioning_queue(status, created_at);

CREATE TABLE IF NOT EXISTS site_provisioning_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    queue_id INTEGER NOT NULL REFERENCES site_provisioning_queue(id) ON DELETE CASCADE,
    site_id TEXT NOT NULL,
    action TEXT NOT NULL DEFAULT '',
    step_key TEXT NOT NULL,
    step_label TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('running', 'done', 'failed', 'info')),
    message TEXT NOT NULL DEFAULT '',
    created_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_site_provisioning_events_queue
    ON site_provisioning_events(queue_id, id);

CREATE INDEX IF NOT EXISTS idx_site_provisioning_events_site
    ON site_provisioning_events(site_id, created_at);

CREATE TABLE IF NOT EXISTS email_delivery_logs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    provider TEXT NOT NULL DEFAULT 'postmark',
    message_id TEXT NOT NULL DEFAULT '',
    email_type TEXT NOT NULL DEFAULT '',
    status TEXT NOT NULL DEFAULT 'unknown',
    from_email TEXT NOT NULL DEFAULT '',
    to_email TEXT NOT NULL DEFAULT '',
    subject TEXT NOT NULL DEFAULT '',
    reason TEXT NOT NULL DEFAULT '',
    provider_response_json TEXT NOT NULL DEFAULT '{}',
    webhook_event_json TEXT NOT NULL DEFAULT '{}',
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    sent_at INTEGER,
    last_event_at INTEGER
);

CREATE INDEX IF NOT EXISTS idx_email_delivery_logs_time
    ON email_delivery_logs(created_at);

CREATE INDEX IF NOT EXISTS idx_email_delivery_logs_message
    ON email_delivery_logs(message_id);

CREATE INDEX IF NOT EXISTS idx_email_delivery_logs_status
    ON email_delivery_logs(status, updated_at);
