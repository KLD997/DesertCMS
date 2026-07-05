package DesertCMS::RichText;

use strict;
use warnings;
use Exporter 'import';
use DesertCMS::Util qw(escape_html);

our @EXPORT_OK = qw(
    sanitize_rich_html plain_text_from_rich_html rich_paragraphs_html
);

my %ALLOWED = map { $_ => 1 } qw(p br strong em s u a ul ol li span);

sub sanitize_rich_html {
    my ($html, $fallback_text) = @_;
    $html = '' unless defined $html;

    if (!length _visible_text($html) && defined $fallback_text && length $fallback_text) {
        return _plain_text_to_html($fallback_text);
    }

    return '' unless length $html;
    $html = substr($html, 0, 250_000);
    $html =~ s/\r\n?/\n/g;
    $html =~ s/<!--.*?-->//gs;
    $html =~ s{<\s*(script|style|iframe|object|embed|svg|math)\b.*?<\s*/\s*\1\s*>}{}gis;
    $html =~ s{<\s*/?\s*(script|style|iframe|object|embed|svg|math)\b[^>]*>}{}gis;
    $html =~ s{<\s*div\b[^>]*>}{<p>}gi;
    $html =~ s{<\s*/\s*div\s*>}{</p>}gi;
    $html =~ s{<\s*(section|article|header|footer)\b[^>]*>}{<p>}gi;
    $html =~ s{<\s*/\s*(section|article|header|footer)\s*>}{</p>}gi;

    my $out = '';
    my @stack;
    my $offset = 0;
    while ($html =~ m{(<[^>]*>)}g) {
        my $tag_start = $-[0];
        my $tag_end = $+[0];
        $out .= escape_html(_decode_entities(substr($html, $offset, $tag_start - $offset)));
        $out .= _clean_tag($1, \@stack);
        $offset = $tag_end;
    }
    $out .= escape_html(_decode_entities(substr($html, $offset)));

    while (@stack) {
        $out .= '</' . pop(@stack) . '>';
    }

    $out =~ s{(?:<p>\s*</p>\s*)+\z}{}g;
    return $out;
}

sub plain_text_from_rich_html {
    my ($html) = @_;
    $html = '' unless defined $html;
    return '' unless length $html;
    $html = substr($html, 0, 250_000);
    $html =~ s/\r\n?/\n/g;
    $html =~ s/<!--.*?-->//gs;
    $html =~ s{<\s*(script|style|iframe|object|embed|svg|math)\b.*?<\s*/\s*\1\s*>}{}gis;
    $html =~ s{<\s*br\s*/?\s*>}{\n}gi;
    $html =~ s{</\s*(?:p|div|li|h[1-6]|blockquote)\s*>}{\n}gi;
    $html =~ s{<[^>]*>}{ }g;
    $html = _decode_entities($html);
    $html =~ s/[ \t]+/ /g;
    $html =~ s/\n[ \t]+/\n/g;
    $html =~ s/[ \t]+\n/\n/g;
    $html =~ s/\n{3,}/\n\n/g;
    $html =~ s/^\s+|\s+$//g;
    return $html;
}

sub rich_paragraphs_html {
    my ($html, $fallback_text) = @_;
    my $clean = sanitize_rich_html($html, $fallback_text);
    return '<p></p>' unless length plain_text_from_rich_html($clean);
    if ($clean !~ m{<(?:p|ul|ol)\b}i) {
        $clean = "<p>$clean</p>";
    }
    return $clean;
}

sub _clean_tag {
    my ($raw, $stack) = @_;
    return '' unless $raw =~ m{\A<\s*(/)?\s*([A-Za-z0-9]+)\b([^>]*)>\z}s;
    my ($closing, $tag, $attrs) = ($1, lc($2), $3 || '');
    $tag = 'strong' if $tag eq 'b';
    $tag = 'em' if $tag eq 'i';
    $tag = 's' if $tag eq 'strike' || $tag eq 'del';
    return '' unless $ALLOWED{$tag};

    if ($tag eq 'br') {
        return '<br>';
    }

    if ($closing) {
        return '' unless grep { $_ eq $tag } @{$stack};
        my $out = '';
        while (@{$stack}) {
            my $open = pop @{$stack};
            $out .= "</$open>";
            last if $open eq $tag;
        }
        return $out;
    }

    if ($tag eq 'a') {
        my $href = _extract_attr($attrs, 'href');
        $href = _clean_href($href);
        return '' unless length $href;
        push @{$stack}, $tag;
        return '<a href="' . escape_html($href) . '">';
    }

    if ($tag eq 'span') {
        my $color = _clean_color(_extract_style_color($attrs) || _extract_attr($attrs, 'color'));
        return '' unless length $color;
        push @{$stack}, $tag;
        return '<span style="color: ' . escape_html($color) . '">';
    }

    push @{$stack}, $tag;
    return "<$tag>";
}

sub _extract_style_color {
    my ($attrs) = @_;
    my $style = _extract_attr($attrs, 'style');
    return '' unless length $style;
    return $1 if $style =~ /(?:^|;)\s*color\s*:\s*([^;]+)\s*(?:;|$)/i;
    return '';
}

sub _extract_attr {
    my ($attrs, $name) = @_;
    return '' unless defined $attrs && length $attrs;
    return _decode_entities($1) if $attrs =~ /\b\Q$name\E\s*=\s*"([^"]*)"/i;
    return _decode_entities($1) if $attrs =~ /\b\Q$name\E\s*=\s*'([^']*)'/i;
    return _decode_entities($1) if $attrs =~ /\b\Q$name\E\s*=\s*([^\s"'=<>`]+)/i;
    return '';
}

sub _clean_href {
    my ($href) = @_;
    $href = '' unless defined $href;
    $href =~ s/^\s+|\s+$//g;
    return '' if length($href) > 500;
    return '' if $href =~ /[\x00-\x1f\x7f<>"\\]/;
    return $href if $href =~ m{\Ahttps?://[A-Za-z0-9._~:/?#\[\]@!\$&'()*+,;=%-]+\z};
    return $href if $href =~ m{\Amailto:[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}(?:\?[A-Za-z0-9._~:/?#\[\]@!\$&'()*+,;=%-]+)?\z};
    return '';
}

sub _clean_color {
    my ($value) = @_;
    $value = '' unless defined $value;
    $value =~ s/^\s+|\s+$//g;
    $value =~ s/\s+/ /g;
    return '' if length($value) > 64;
    return $value if $value =~ /\Avar\(--(?:accent|support|danger|muted|ink)\)\z/;
    return lc($value) if $value =~ /\A#[0-9A-Fa-f]{6}\z/;
    return '';
}

sub _plain_text_to_html {
    my ($text) = @_;
    $text = '' unless defined $text;
    $text =~ s/\r\n?/\n/g;
    my $html = '';
    for my $paragraph (split /\n\s*\n/, $text) {
        $paragraph =~ s/^\s+|\s+$//g;
        next unless length $paragraph;
        my $safe = escape_html($paragraph);
        $safe =~ s/\n/<br>/g;
        $html .= "<p>$safe</p>\n";
    }
    $html =~ s/\n+\z//;
    return $html;
}

sub _visible_text {
    my ($html) = @_;
    return plain_text_from_rich_html($html);
}

sub _decode_entities {
    my ($text) = @_;
    $text = '' unless defined $text;
    $text =~ s/&lt;/</gi;
    $text =~ s/&gt;/>/gi;
    $text =~ s/&quot;/"/gi;
    $text =~ s/&#39;/'/gi;
    $text =~ s/&apos;/'/gi;
    $text =~ s/&#x([0-9A-Fa-f]+);/chr(hex($1))/eg;
    $text =~ s/&#([0-9]+);/chr($1)/eg;
    $text =~ s/&amp;/&/gi;
    return $text;
}

1;
