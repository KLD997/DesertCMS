package DesertCMS::Docs;

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Basename qw(basename dirname);
use File::Find;
use File::Spec;
use DesertCMS::Util qw(escape_html slugify);

sub new {
    my ($class, %args) = @_;
    die "config is required" unless $args{config};
    return bless {
        config => $args{config},
    }, $class;
}

sub docs_dir {
    my ($self, $settings) = @_;
    $settings ||= {};
    my $configured = $settings->{docs_source_dir} || $self->{config}->get('docs_source_dir') || '';
    $configured =~ s/^\s+|\s+\z//g;
    return _normalize_dir($configured) if length $configured;

    my $module_path = $INC{'DesertCMS/Docs.pm'} || __FILE__;
    my $app_root = dirname(dirname(dirname($module_path)));
    return _normalize_dir(File::Spec->catdir($app_root, 'docs'));
}

sub documents {
    my ($self, %args) = @_;
    my $settings = $args{settings} || {};
    my $dir = $self->docs_dir($settings);
    return [] unless length $dir && -d $dir;

    my @paths;
    find(
        {
            no_chdir => 1,
            wanted   => sub {
                return if -d $File::Find::name;
                return if -l $File::Find::name;
                return unless $File::Find::name =~ /\.md\z/i;
                my $rel = File::Spec->abs2rel($File::Find::name, $dir);
                $rel =~ s{\\}{/}g;
                return if $rel =~ m{(?:\A|/)\.};
                push @paths, $File::Find::name;
            },
        },
        $dir
    );

    my @docs;
    for my $path (sort @paths) {
        my $doc = eval { $self->_document_from_file($dir, $path) };
        push @docs, $doc if $doc;
    }
    @docs = sort {
        ($a->{order} <=> $b->{order})
            || lc($a->{title}) cmp lc($b->{title})
            || $a->{slug} cmp $b->{slug}
    } @docs;
    return \@docs;
}

sub document {
    my ($self, $slug, %args) = @_;
    $slug = _clean_slug($slug);
    for my $doc (@{$self->documents(%args)}) {
        return $doc if $doc->{slug} eq $slug;
    }
    return undef;
}

sub render_markdown {
    my ($class_or_self, $markdown) = @_;
    $markdown = '' unless defined $markdown;
    $markdown =~ s/\r\n?/\n/g;
    $markdown = substr($markdown, 0, 1_000_000);

    my @lines = split /\n/, $markdown, -1;
    my $html = '';
    my $i = 0;
    while ($i < @lines) {
        my $line = $lines[$i];
        if ($line =~ /^\s*\z/) {
            $i++;
            next;
        }

        if ($line =~ /^\s*```([A-Za-z0-9_-]+)?\s*\z/) {
            my $lang = _clean_language($1 || '');
            $i++;
            my @code;
            while ($i < @lines && $lines[$i] !~ /^\s*```\s*\z/) {
                push @code, $lines[$i++];
            }
            $i++ if $i < @lines;
            my $class = length $lang ? ' class="language-' . escape_html($lang) . '"' : '';
            $html .= '<pre class="docs-code"><code' . $class . '>' . escape_html(join("\n", @code)) . "\n</code></pre>\n";
            next;
        }

        if ($line =~ /^(#{1,6})\s+(.+?)\s*#*\s*\z/) {
            my $level = length($1);
            my $text = _strip_inline_markers($2);
            my $id = slugify($text);
            $html .= '<h' . $level . ' id="' . escape_html($id) . '">'
                . _inline($2) . '</h' . $level . ">\n";
            $i++;
            next;
        }

        if ($line =~ /^\s*(?:---+|\*\*\*+|___+)\s*\z/) {
            $html .= "<hr>\n";
            $i++;
            next;
        }

        if (_looks_like_table(\@lines, $i)) {
            my ($table, $next) = _render_table(\@lines, $i);
            $html .= $table;
            $i = $next;
            next;
        }

        if ($line =~ /^\s{0,3}>\s?(.*)\z/) {
            my @quote;
            while ($i < @lines && $lines[$i] =~ /^\s{0,3}>\s?(.*)\z/) {
                push @quote, $1;
                $i++;
            }
            $html .= '<blockquote>' . render_markdown(__PACKAGE__, join("\n", @quote)) . "</blockquote>\n";
            next;
        }

        if ($line =~ /^\s{0,3}([-*+])\s+(.+)\z/) {
            my @items;
            while ($i < @lines && $lines[$i] =~ /^\s{0,3}[-*+]\s+(.+)\z/) {
                push @items, $1;
                $i++;
            }
            $html .= "<ul>\n" . join('', map { '<li>' . _inline($_) . "</li>\n" } @items) . "</ul>\n";
            next;
        }

        if ($line =~ /^\s{0,3}[0-9]+[.)]\s+(.+)\z/) {
            my @items;
            while ($i < @lines && $lines[$i] =~ /^\s{0,3}[0-9]+[.)]\s+(.+)\z/) {
                push @items, $1;
                $i++;
            }
            $html .= "<ol>\n" . join('', map { '<li>' . _inline($_) . "</li>\n" } @items) . "</ol>\n";
            next;
        }

        my @paragraph;
        while ($i < @lines && $lines[$i] !~ /^\s*\z/ && !_starts_block(\@lines, $i)) {
            push @paragraph, $lines[$i];
            $i++;
        }
        my $text = join ' ', map { s/^\s+|\s+\z//gr } @paragraph;
        $html .= '<p>' . _inline($text) . "</p>\n" if length $text;
    }

    return $html;
}

sub strip_title_heading {
    my ($class_or_self, $markdown, $title) = @_;
    $markdown = '' unless defined $markdown;
    $title = '' unless defined $title;
    $markdown =~ s/\r\n?/\n/g;
    my $safe = quotemeta($title);
    $markdown =~ s/\A\s*#\s+$safe\s*\n+//i if length $safe;
    return $markdown;
}

sub _document_from_file {
    my ($self, $dir, $path) = @_;
    my $rel = File::Spec->abs2rel($path, $dir);
    $rel =~ s{\\}{/}g;
    my $body = _read_file($path);
    my ($meta, $markdown) = _front_matter($body);
    my $title = $meta->{title} || _first_heading($markdown) || _title_from_rel($rel);
    my $summary = $meta->{summary} || $meta->{description} || _first_paragraph($markdown);
    my $audience = _clean_audience($meta->{audience} || $meta->{category} || '');
    my $resource_type = _clean_resource_type($meta->{resource_type} || $meta->{type} || $meta->{kind} || '');
    my @tags = _clean_tags($meta->{tags} || $meta->{keywords} || '');
    my $updated = _clean_short_text($meta->{updated} || $meta->{updated_at} || $meta->{date} || '', 40);
    my $access = _clean_access($meta->{access} || '');
    my $public_access = _access_is_public($access);
    my $slug = _slug_for_rel($rel);
    my $order = defined $meta->{order} && $meta->{order} =~ /^-?[0-9]+$/ ? int($meta->{order}) : 1000;
    my $body_markdown = __PACKAGE__->strip_title_heading($markdown, $title);

    return {
        title         => $title,
        summary       => $summary,
        audience      => $audience,
        resource_type => $resource_type,
        access        => $access,
        public_access => $public_access,
        public_status => $public_access ? 'Public page' : 'Held in admin',
        updated       => $updated,
        tags          => \@tags,
        tags_label    => join(', ', @tags),
        slug          => $slug,
        url           => '/docs/' . $slug . '/',
        source_path   => $path,
        source_rel    => $rel,
        order         => $order,
        markdown      => $markdown,
        html          => __PACKAGE__->render_markdown($body_markdown),
    };
}

sub _front_matter {
    my ($body) = @_;
    $body = '' unless defined $body;
    $body =~ s/\r\n?/\n/g;
    my %meta;
    if ($body =~ s/\A---\n(.*?)\n---\n?//s) {
        for my $line (split /\n/, $1) {
            next unless $line =~ /^\s*([A-Za-z0-9_-]+)\s*:\s*(.*?)\s*\z/;
            my ($key, $value) = (lc($1), $2);
            $value =~ s/\A["']|["']\z//g;
            $meta{$key} = $value;
        }
    }
    return (\%meta, $body);
}

sub _first_heading {
    my ($markdown) = @_;
    return $1 if defined $markdown && $markdown =~ /^\s*#\s+(.+?)\s*#*\s*$/m;
    return '';
}

sub _first_paragraph {
    my ($markdown) = @_;
    return '' unless defined $markdown;
    my @lines = split /\n/, $markdown;
    my @paragraph;
    for my $line (@lines) {
        next if $line =~ /^\s*#/;
        next if $line =~ /^\s*```/;
        if ($line =~ /^\s*\z/) {
            last if @paragraph;
            next;
        }
        push @paragraph, $line;
    }
    my $text = join ' ', @paragraph;
    $text = _strip_inline_markers($text);
    $text =~ s/\s+/ /g;
    $text =~ s/^\s+|\s+\z//g;
    return substr($text, 0, 240);
}

sub _title_from_rel {
    my ($rel) = @_;
    $rel =~ s{\\}{/}g;
    my $name = basename($rel);
    $name =~ s/\.md\z//i;
    $name =~ s/[-_]+/ /g;
    $name =~ s/\b([a-z])/\U$1/g;
    return $name || 'Documentation';
}

sub _slug_for_rel {
    my ($rel) = @_;
    $rel =~ s{\\}{/}g;
    $rel =~ s/\.md\z//i;
    $rel =~ s{/(?:index|readme)\z}{}i;
    $rel = 'overview' if $rel =~ /^(?:index|readme)\z/i;
    my @segments = grep { length } map { slugify($_) } split m{/+}, $rel;
    return join '/', @segments;
}

sub _clean_slug {
    my ($slug) = @_;
    $slug = '' unless defined $slug;
    $slug =~ s{\\}{/}g;
    $slug =~ s{\A/+|/+\z}{}g;
    my @segments = grep { length } map { slugify($_) } split m{/+}, $slug;
    return join '/', @segments;
}

sub _clean_audience {
    my ($audience) = @_;
    $audience = '' unless defined $audience;
    $audience =~ s/^\s+|\s+\z//g;
    $audience =~ s/[_-]+/ /g;
    $audience =~ s/\s+/ /g;
    return 'Site Management' if $audience =~ /\A(?:site management|site owner|owner|user|non technical|nontechnical)\z/i;
    return 'Technical' if $audience =~ /\A(?:technical|developer|operator|engineering)\z/i;
    return 'General' unless length $audience;
    $audience = substr($audience, 0, 60);
    $audience =~ s/\b([a-z])/\U$1/g;
    return $audience;
}

sub _clean_resource_type {
    my ($type) = @_;
    $type = '' unless defined $type;
    $type =~ s/^\s+|\s+\z//g;
    $type =~ s/[_-]+/ /g;
    $type =~ s/\s+/ /g;
    return 'Guide' if $type =~ /\A(?:guide|how to|tutorial|walkthrough)\z/i;
    return 'FAQ' if $type =~ /\A(?:faq|faqs|frequently asked questions)\z/i;
    return 'Local Archive' if $type =~ /\A(?:archive|local archive|collection|history|local history)\z/i;
    return 'Member Resource' if $type =~ /\A(?:member|members|member resource|members resource|member resources)\z/i;
    return 'Help Center' if $type =~ /\A(?:help|help center|support|support article|knowledge base)\z/i;
    return 'Reference' if $type =~ /\A(?:reference|technical reference|api|manual)\z/i;
    return 'Documentation' unless length $type;
    $type = substr($type, 0, 40);
    $type =~ s/\b([a-z])/\U$1/g;
    return $type;
}

sub _clean_access {
    my ($access) = @_;
    $access = '' unless defined $access;
    $access =~ s/^\s+|\s+\z//g;
    $access =~ s/[_-]+/ /g;
    $access =~ s/\s+/ /g;
    return 'Public' unless length $access;
    return 'Public' if $access =~ /\A(?:public|open)\z/i;
    return 'Members only' if $access =~ /\A(?:member|members|member only|members only|member resource|member resources)\z/i;
    return 'Staff only' if $access =~ /\A(?:staff|internal|operator)\z/i;
    return 'Private' if $access =~ /\A(?:private|restricted|hidden|draft)\z/i;
    return _clean_short_text($access, 40);
}

sub _access_is_public {
    my ($access) = @_;
    $access = '' unless defined $access;
    return $access eq 'Public' ? 1 : 0;
}

sub _clean_tags {
    my ($tags) = @_;
    $tags = '' unless defined $tags;
    $tags =~ s/^\s*\[|\]\s*\z//g;
    my @tags;
    for my $tag (split /[,;|]/, $tags) {
        $tag = _clean_short_text($tag, 32);
        next unless length $tag;
        next if grep { lc($_) eq lc($tag) } @tags;
        push @tags, $tag;
        last if @tags >= 6;
    }
    return @tags;
}

sub _clean_short_text {
    my ($text, $max) = @_;
    $text = '' unless defined $text;
    $max ||= 60;
    $text =~ s/^\s+|\s+\z//g;
    $text =~ s/["']//g;
    $text =~ s/[<>\x00-\x1f\x7f]//g;
    $text =~ s/\s+/ /g;
    $text = substr($text, 0, $max);
    $text =~ s/\s+\z//g;
    $text =~ s/\b([a-z])/\U$1/g if $text !~ /\A[0-9]{4}(?:-[0-9]{2}){0,2}\z/;
    return $text;
}

sub _looks_like_table {
    my ($lines, $i) = @_;
    return 0 if $i + 1 >= @{$lines};
    return 0 unless $lines->[$i] =~ /\|/;
    return $lines->[$i + 1] =~ /^\s*\|?\s*:?-{3,}:?\s*(?:\|\s*:?-{3,}:?\s*)+\|?\s*\z/ ? 1 : 0;
}

sub _render_table {
    my ($lines, $i) = @_;
    my @headers = _split_table_row($lines->[$i]);
    $i += 2;
    my $html = "<table class=\"docs-table\">\n<thead><tr>"
        . join('', map { '<th>' . _inline($_) . '</th>' } @headers)
        . "</tr></thead>\n<tbody>\n";
    while ($i < @{$lines} && $lines->[$i] =~ /\|/ && $lines->[$i] !~ /^\s*\z/) {
        my @cells = _split_table_row($lines->[$i]);
        $html .= '<tr>' . join('', map { '<td>' . _inline($_) . '</td>' } @cells) . "</tr>\n";
        $i++;
    }
    $html .= "</tbody>\n</table>\n";
    return ($html, $i);
}

sub _split_table_row {
    my ($line) = @_;
    $line =~ s/^\s*\|//;
    $line =~ s/\|\s*\z//;
    return map {
        my $cell = $_;
        $cell =~ s/^\s+|\s+\z//g;
        $cell;
    } split /\|/, $line;
}

sub _starts_block {
    my ($lines, $i) = @_;
    my $line = $lines->[$i] // '';
    return 1 if $line =~ /^\s*```/;
    return 1 if $line =~ /^(#{1,6})\s+/;
    return 1 if $line =~ /^\s{0,3}>/;
    return 1 if $line =~ /^\s{0,3}[-*+]\s+/;
    return 1 if $line =~ /^\s{0,3}[0-9]+[.)]\s+/;
    return 1 if _looks_like_table($lines, $i);
    return 0;
}

sub _inline {
    my ($text) = @_;
    $text = '' unless defined $text;
    my @tokens;
    $text =~ s{`([^`\n]+)`}{_token(\@tokens, '<code>' . escape_html($1) . '</code>')}eg;
    $text =~ s/!\[([^\]]*)\]\(([^)\s]+)\)/_image_token(\@tokens, $1, $2)/eg;
    $text =~ s/\[([^\]]+)\]\(([^)\s]+)\)/_link_token(\@tokens, $1, $2)/eg;

    my $html = escape_html($text);
    $html =~ s/\*\*([^*]+)\*\*/<strong>$1<\/strong>/g;
    $html =~ s/__([^_]+)__/<strong>$1<\/strong>/g;
    $html =~ s/(?<!\*)\*([^*\n]+)\*(?!\*)/<em>$1<\/em>/g;
    $html =~ s/(?<!_)_([^_\n]+)_(?!_)/<em>$1<\/em>/g;
    $html =~ s/~~([^~]+)~~/<s>$1<\/s>/g;

    for my $i (0 .. $#tokens) {
        my $needle = 'DESERTCMSDOCSTOKEN' . $i . 'END';
        my $value = $tokens[$i];
        $html =~ s/\Q$needle\E/$value/g;
    }
    return $html;
}

sub _token {
    my ($tokens, $html) = @_;
    push @{$tokens}, $html;
    return 'DESERTCMSDOCSTOKEN' . $#{$tokens} . 'END';
}

sub _link_token {
    my ($tokens, $label, $url) = @_;
    my $clean = _clean_url($url);
    return $label unless length $clean;
    return _token($tokens, '<a href="' . escape_html($clean) . '">' . escape_html($label) . '</a>');
}

sub _image_token {
    my ($tokens, $alt, $url) = @_;
    my $clean = _clean_url($url);
    return $alt unless length $clean;
    return _token($tokens, '<img src="' . escape_html($clean) . '" alt="' . escape_html($alt) . '" loading="lazy">');
}

sub _clean_url {
    my ($url) = @_;
    $url = '' unless defined $url;
    $url =~ s/^\s+|\s+\z//g;
    $url =~ s/\A["']|["']\z//g;
    return '' if $url eq '' || length($url) > 500;
    return '' if $url =~ /[\x00-\x1f\x7f<>"\\]/;
    return '' if $url =~ /^\s*(?:javascript|data):/i;
    return $url if $url =~ m{\Ahttps?://[A-Za-z0-9._~:/?#\[\]@!\$&'()*+,;=%-]+\z};
    return $url if $url =~ m{\Amailto:[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}(?:\?[A-Za-z0-9._~:/?#\[\]@!\$&'()*+,;=%-]+)?\z};
    return $url if $url =~ m{\A/[A-Za-z0-9._~:/?#\[\]@!\$&'()*+,;=%-]*\z};
    return $url if $url =~ m{\A#[A-Za-z0-9_-]+\z};
    if ($url =~ /\.md(?:#[A-Za-z0-9_-]+)?\z/i) {
        my ($path, $anchor) = split /#/, $url, 2;
        $path =~ s{\\}{/}g;
        $path =~ s{\A(?:\./|\.\./)+}{};
        $path =~ s{\Adocs/}{};
        my $slug = _slug_for_rel($path);
        return '/docs/' . $slug . '/' . (defined $anchor && length $anchor ? '#' . slugify($anchor) : '');
    }
    return $url if $url =~ m{\A[A-Za-z0-9._~/-]+\z};
    return '';
}

sub _strip_inline_markers {
    my ($text) = @_;
    $text = '' unless defined $text;
    $text =~ s/`([^`]+)`/$1/g;
    $text =~ s/!\[([^\]]*)\]\([^)]+\)/$1/g;
    $text =~ s/\[([^\]]+)\]\([^)]+\)/$1/g;
    $text =~ s/[*_~#>`]+//g;
    $text =~ s/\s+/ /g;
    $text =~ s/^\s+|\s+\z//g;
    return $text;
}

sub _clean_language {
    my ($language) = @_;
    $language = lc($language || '');
    $language =~ s/[^a-z0-9_-]//g;
    return substr($language, 0, 32);
}

sub _normalize_dir {
    my ($dir) = @_;
    return '' unless defined $dir && length $dir;
    my $abs = abs_path($dir);
    return defined $abs ? $abs : $dir;
}

sub _read_file {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read documentation file $path: $!";
    local $/;
    my $body = <$fh>;
    close $fh;
    return defined $body ? $body : '';
}

1;
