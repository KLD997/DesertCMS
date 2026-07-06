use strict;
use warnings;
use Test::More;
use File::Spec;

use FindBin;

my $root = File::Spec->catdir($FindBin::Bin, '..');
my $docs_dir = File::Spec->catdir($root, 'docs');

my @expected = qw(
    BILLING_AND_PROVIDER_OPTIONS.md
    CONTENT_DESIGN_AND_MEDIA.md
    CREATING_MODULES.md
    INTEGRATIONS_AND_COMMERCE.md
    MANAGING_CONTRIBUTOR_SITES.md
    OPENBSD_74_INSTALL.md
    OPERATIONS_AND_RECOVERY.md
    PRIVACY_AND_DATA.md
    SITE_OWNER_GUIDE.md
    TECHNICAL_ARCHITECTURE.md
    V3_RUNTIME_ROADMAP.md
);

my @removed = qw(
    ADMIN_GUIDE.md
    ARCHITECTURE.md
    CONTRIBUTOR_SITES.md
    CUSTOM_MODULES.md
    DEPLOYMENT_TARGETS.md
    GEOIP_ANALYTICS.md
    OPENBSD_DEPLOY.md
    OPENBSD_INSTALL.md
    PROVIDER_INTEGRATIONS.md
    SHOP.md
    SITE_CUSTOMIZATION.md
    UPGRADES.md
    VULTR_OPENBSD_INSTALL.md
    WEBSERVERS.md
);

my %expected = map { $_ => 1 } @expected;
my %removed = map { $_ => 1 } @removed;
my %internal_planning = (
    'V3_RUNTIME_ROADMAP.md' => 1,
);

opendir my $dh, $docs_dir or die "cannot read $docs_dir: $!";
my @files = sort grep { /\.md\z/ } readdir $dh;
closedir $dh;
my %files = map { $_ => 1 } @files;

is_deeply(\@files, \@expected, 'repo documentation is the rebuilt Technical and Site Management set');

for my $file (@removed) {
    ok(!$files{$file}, "$file is not shipped as current documentation");
}

my $site_management = 0;
my $technical = 0;
my $guide = 0;
my $reference = 0;
my $all_docs = '';
for my $file (@expected) {
    my $body = _read(File::Spec->catfile($docs_dir, $file));
    if ($internal_planning{$file}) {
        like($body, qr/\A---\n(?:.*\n)*?title:\s+.+\n(?:.*\n)*?summary:\s+.+\n(?:.*\n)*?audience:\s+Technical\n(?:.*\n)*?resource_type:\s+Planning\n(?:.*\n)*?tags:\s+.+\n(?:.*\n)*?updated:\s+20\d\d-\d\d-\d\d\n(?:.*\n)*?access:\s+Internal\n(?:.*\n)*?order:\s+\d+\n---\n/s, "$file has complete internal planning front matter");
        $all_docs .= "\n$file\n$body\n";
        next;
    }
    like($body, qr/\A---\n(?:.*\n)*?title:\s+.+\n(?:.*\n)*?summary:\s+.+\n(?:.*\n)*?audience:\s+(?:Site Management|Technical)\n(?:.*\n)*?resource_type:\s+(?:Guide|Reference)\n(?:.*\n)*?tags:\s+.+\n(?:.*\n)*?updated:\s+20\d\d-\d\d-\d\d\n(?:.*\n)*?access:\s+Public\n(?:.*\n)*?order:\s+\d+\n---\n/s, "$file has complete Resource Hub front matter");
    $site_management++ if $body =~ /^audience:\s+Site Management\s*$/m;
    $technical++ if $body =~ /^audience:\s+Technical\s*$/m;
    $guide++ if $body =~ /^resource_type:\s+Guide\s*$/m;
    $reference++ if $body =~ /^resource_type:\s+Reference\s*$/m;
    $all_docs .= "\n$file\n$body\n";
}

is($site_management, 5, 'five docs are Site Management docs');
is($technical, 5, 'five docs are Technical docs');
is($guide, 6, 'six bundled docs are Resource Hub guides');
is($reference, 4, 'four bundled docs are Resource Hub references');
like($all_docs, qr/Technical Architecture/, 'technical architecture is documented');
like($all_docs, qr/OpenBSD 7\.4 Installation/, 'OpenBSD 7.4 installation is documented');
like($all_docs, qr/Creating Modules/, 'module creation is documented');
like($all_docs, qr/Managing Contributor Sites/, 'non-technical contributor-site management is documented');
like($all_docs, qr/private source asset/i, 'general media pipeline language is documented');
like($all_docs, qr/OpenBSD installation and provider activation are separate milestones/, 'provider docs distinguish install completion from provider activation');
like($all_docs, qr/Missing Postmark sender\/token\/webhook token or Stripe webhook secrets are provider setup warnings/, 'provider docs classify missing Postmark and Stripe secrets as provider setup warnings');
like($all_docs, qr/provider warnings mean the operator still needs to finish MasterCMS provider setup before enabling email sends, billing checkout, or site payments/, 'OpenBSD install docs explain provider warnings after a valid base install');
unlike($all_docs, qr/\bVPS\b|Vultr/, 'current docs do not include provider-specific server docs language');

done_testing;

sub _read {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    my $body = <$fh>;
    close $fh;
    return defined $body ? $body : '';
}
