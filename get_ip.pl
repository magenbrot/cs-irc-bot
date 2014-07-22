#!/usr/bin/perl -w

use LWP::UserAgent;
use HTTP::Request;

$url = "http://www.independent-lords.de/cgi-bin/rem_ip.pl";
my $ua = LWP::UserAgent->new();
$ua->agent("Braindead/v1.0");
my $anf = HTTP::Request->new(GET => $url);
$anf->referer("http://ibot.de");

my $antwort = $ua->request($anf);

if ($antwort->is_error()) {
  printf " %s\n", $antwort->status_line;
}
else {
  my $anzahl;
  my $bytes;
  my $inhalt = $antwort->content();
  print $inhalt;
}
