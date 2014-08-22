package Mojo::Crawler;
use strict;
use warnings;
use Mojo::Base 'Mojo::IOLoop';
use Mojo::Crawler::Queue;
use Mojo::UserAgent;
use Mojo::Util qw{md5_sum xml_escape};
our $VERSION = '0.01';

has after_crawl => sub { sub {} };
has 'ua';
has 'ua_name' => "mojo-crawler/$VERSION (+https://github.com/jamadam/mojo-checkbot)";
has credentials => sub { {} };
has depth => 10;
has fix => sub { {} };
has keep_credentials => 1;
has on_refer => sub { sub { shift->() } };
has on_res => sub { sub { shift->() } };
has on_error => sub {
    sub {
        my ($self, $msg) = @_;
        print STDERR "$msg\n";
    }
};
has queues => sub { [] };

sub new {
    my $class = shift;
    my $self = $class->SUPER::new(@_);
    
    my $ua = Mojo::UserAgent->new;
    $self->ua($ua);
    $ua->transactor->name($self->ua_name);
    $ua->max_redirects(5);
    
    if ($self->keep_credentials) {
        $ua->on(start => sub {
            my ($ua, $tx) = @_;
            my $url = $tx->req->url;
            if ($url->is_abs) {
                my $key = $url->scheme. '://'. $url->host. ':'. ($url->port || 80);
                if ($url->userinfo) {
                    $self->credentials->{$key} = $url->userinfo;
                } else {
                    $url->userinfo($self->credentials->{$key});
                }
            }
        });
    }
    
    return $self;
}

our $NEW_QUEUE = {};

sub crawl {
    my ($self) = @_;
    
    my $loop_id;
    $loop_id = Mojo::IOLoop->recurring(1 => sub {
        
        return unless (my $queue = shift @{$self->{queues}});
        
        my $url = $queue->resolved_uri;
        my $tx = $self->ua->get($url);
        
        if ($tx->res->error) {
            my $msg = $tx->res->error->{message};
            $self->on_error->($self, "An error occured during crawling $url: $msg");
            return;
        } elsif ($@) {
            $self->on_error->($self, "An error occured during crawling $url: $@");
            return;
        }
        
        $self->on_res->(sub {
            $self->find_queue($tx, $queue);
        }, $queue, $tx);
    });
    
    Mojo::IOLoop->start;
}

sub find_queue {
    my ($self, $tx, $queue) = @_;
    
    if ($tx->res->code == 200 &&
                    (! $self->depth || $queue->depth < $self->depth)) {
        
        my $base;
        
        if ($tx->res->headers->content_type =~ qr{text/(html|xml)} &&
                        (my $base_tag = $tx->res->dom->at('base'))) {
            $base = $base_tag->attr('href');
        } else {
            # TODO Is this OK for redirected urls?
            $base = $tx->req->url->userinfo(undef);
        }
        
        collect_urls($tx, sub {
            my ($newurl, $dom) = @_;
            
            if ($newurl =~ qr{^(\w+):} &&
                        ! grep {$_ eq $1} qw(http https ftp ws wss)) {
                return;
            }
            
            $newurl = resolve_href($base, $newurl);
            
            local $NEW_QUEUE = Mojo::Crawler::Queue->new(
                resolved_uri    => $newurl,
                literal_uri     => $newurl,
                parent          => $queue,
            );
            
            my $append_cb = sub {
                $self->enqueue($_[0] || $newurl)
            };
            
            $self->on_refer->(
                $append_cb, $NEW_QUEUE, $queue, $dom || $queue->resolved_uri);
        });
    }
    
    $self->after_crawl->($queue, $tx);
};

sub enqueue {
    my ($self, $url) = @_;
    
    my $queue;
    
    if ($url) {
        $queue = Mojo::Crawler::Queue->new(
                                    literal_uri => $url, resolved_uri => $url);
    } else {
        $queue = $NEW_QUEUE;
    }
    
    my $md5 = md5_sum($queue->resolved_uri);
    
    if (! exists $self->fix->{$md5}) {
        
        $self->fix->{$md5} = undef;
        
        push(@{$self->{queues}}, $queue);
    }
}

sub collect_urls {
    my ($tx, $cb) = @_;
    my $res     = $tx->res;
    my $type    = $res->headers->content_type;
    my @hrefs;
    
    if ($type && $type =~ qr{text/(html|xml)}) {
        my $body = Encode::decode(guess_encoding($res) || 'utf-8', $res->body);
        my $dom = Mojo::DOM->new($body);
        
        return collect_urls_html($dom, $cb);
    }
    
    if ($type && $type =~ qr{text/css}) {
        my $encode  = guess_encoding_css($res) || 'utf-8';
        my $body    = Encode::decode($encode, $res->body);
        collect_urls_css($body, sub {
            $cb->(shift);
        })
    }
    
    return;
}

### ---
### Collect URLs
### ---
sub collect_urls_html {
    my ($dom, $cb) = @_;
    
    $dom->find('script, link, a, img, area, embed, frame, iframe, input,
                                    meta[http\-equiv=Refresh]')->each(sub {
        my $dom = shift;
        if (my $href = $dom->{href} || $dom->{src} ||
            $dom->{content} && ($dom->{content} =~ qr{URL=(.+)}i)[0]) {
            $cb->($href, $dom);
        }
    });
    $dom->find('form')->each(sub {
        my $dom = shift;
        if (my $href = $dom->{action}) {
            $cb->($href, $dom);
        }
    });
    $dom->find('style')->each(sub {
        my $dom = shift;
        collect_urls_css($dom->content || '', sub {
            my $href = shift;
            $cb->($href, $dom);
        });
    });
}

### ---
### Collect URLs from CSS
### ---
sub collect_urls_css {
    my ($str, $cb) = @_;
    $str =~ s{/\*.+?\*/}{}gs;
    my @urls = ($str =~ m{url\(['"]?(.+?)['"]?\)}g);
    $cb->($_) for (@urls);
}

### ---
### Guess encoding for CSS
### ---
sub guess_encoding_css {
    my $res     = shift;
    my $type    = $res->headers->content_type;
    my $charset = ($type =~ qr{; ?charset=([^;\$]+)})[0];
    if (! $charset) {
        $charset = ($res->body =~ qr{^\s*\@charset ['"](.+?)['"];}is)[0];
    }
    return $charset;
}

### ---
### Guess encoding
### ---
sub guess_encoding {
    my $res     = shift;
    my $type    = $res->headers->content_type;
    my $charset = ($type =~ qr{; ?charset=([^;\$]+)})[0];
    if (! $charset && (my $head = ($res->body =~ qr{<head>(.+)</head>}is)[0])) {
        my $dom = Mojo::DOM->new($head);
        $dom->find('meta[http\-equiv=Content-Type]')->each(sub{
            my $meta_dom = shift;
            $charset = ($meta_dom->{content} =~ qr{; ?charset=([^;\$]+)})[0];
        });
    }
    return $charset;
}

### ---
### Resolve href
### ---
sub resolve_href {
    my ($base, $href) = @_;
    if (! ref $base) {
        $base = Mojo::URL->new($base);
    }
    my $new = $base->clone;
    my $temp = Mojo::URL->new($href);
    
    $temp->fragment(undef);
    if ($temp->scheme) {
        return $temp->to_string;
    }
    
    if ($temp->path->to_string) {
        $new->path($temp->path->to_string);
        $new->path->canonicalize;
    }
    
    if ($temp->host) {
        $new->host($temp->host);
    }
    if ($temp->port) {
        $new->port($temp->port);
    }
    $new->query($temp->query);
    while ($new->path->parts->[0] && $new->path->parts->[0] =~ /^\./) {
        shift @{$new->path->parts};
    }
    return $new->to_string;
}

1;

=head1 NAME

Mojo::Crawler - 

=head1 SYNOPSIS

=head1 DESCRIPTION

=head1 METHODS

=head1 AUTHOR

Sugama Keita, E<lt>sugama@jamadam.comE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) jamadam

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

=cut
