use strict;
use warnings;
use Test::More;

plan( tests => 18);

use_ok("Crypt::Rijndael");
use_ok("MIME::Base64");
use_ok("GearmanProxy");

my $keys = [
    "",
    "1234",
    "0" x 64,
    "file:t/testkey",
];

my $data = [
    "",
    "1234",
    "0" x 64,
];

my $proxy = GearmanProxy->new({});
my $x = 1;
for my $key (@{$keys}) {
    for my $d (@{$data}) {
        my $enc = $proxy->_encrypt($d, $key);
        my $dec = $proxy->_decrypt($enc, $key);
        is($dec, $d, "en/decryption worked with key $x");
    }
    $x++;
}

isnt(undef, $proxy->{'cipher_cache'}->{"file:t/testkey"}, "cipher has been cached");
isa_ok($proxy->{'cipher_cache'}->{"file:t/testkey"}, "Crypt::Rijndael");


my $enc = $proxy->_encrypt($data->[1], "file:t/testkey");
my $dec = $proxy->_decrypt($enc, "secret");
is($dec, $data->[1], "en/decryption worked with key from file");