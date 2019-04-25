#!/usr/bin/perl

# Copyright 2015 PTFS Europe
#
# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it under the
# terms of the GNU General Public License as published by the Free Software
# Foundation; either version 3 of the License, or (at your option) any later
# version.
#
# Koha is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with Koha; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

use CGI qw( -utf8 );

use C4::Context;
use C4::Circulation;
use C4::Auth;
use Koha::Account;
use Koha::Account::Lines;
use Koha::Patrons;
use Koha::Plugin::Com::PTFSEurope::WPMPayments;

use XML::LibXML;
use Digest::MD5 qw(md5_hex);

my $paymentHandler = Koha::Plugin::Com::PTFSEurope::WPMPayments->new;

# Parse XML
binmode STDIN, ':encoding(UTF-8)';
my $xml_string;
while (<STDIN>) {
    $xml_string .= $_;
}
my $xml;
eval { $xml = XML::LibXML->load_xml( string => $xml_string ); };
warn "error: " . $@ if $@;

my $borrowernumber = $xml->findvalue('/wpmpaymentrequest/customerid');
my $transaction_id = $xml->findvalue('/wpmpaymentrequest/transactionreference');
my $success        = $xml->findvalue('/wpmpaymentrequest/transaction/success');

my $borrower = Koha::Patrons->find($borrowernumber);

if ( $success eq '1' ) {

    # Extract accountlines to pay
    my @accountline_ids = ();
    my $payments_nodes  = $xml->findnodes('/wpmpaymentrequest/payments');
    for my $payments_node ( $payments_nodes->get_nodelist ) {
        my $payment_nodes = $payments_node->findnodes('./payment');
        for my $payment_node ( $payment_nodes->get_nodelist ) {
            if ( $payment_node->findvalue('./@paid') ) {
                my $accountline = $payment_node->findvalue('./@payid');
                push @accountline_ids, $accountline;
            }
        }
    }

    my $totalpaid = $xml->findvalue('/wpmpaymentrequest/transaction/totalpaid');

    # Prepare transaction logging
    my $dbh = C4::Context->dbh;
    my $table = $paymentHandler->get_qualified_table_name('wpm_transactions');
    $dbh->do("DELETE FROM $table WHERE transaction_id = $transaction_id;");
    my $sth   = $dbh->prepare(
        "INSERT INTO $table (accountline_id, transaction_id) VALUES ( ?, ? )");

    # Make Payments
    my $account = Koha::Account->new( { patron_id => $borrowernumber } );
    my $lines = Koha::Account::Lines->search(
        { accountlines_id => { 'in' => \@accountline_ids } } )->as_list;
    for my $line ( @{$lines} ) {
        my $to_pay = $line->amountoutstanding;
        $totalpaid = $totalpaid - $to_pay;
        if ( $totalpaid > 0 ) {
            my $credit = $account->add_credit(
                {
                    amount     => $to_pay,
                    note       => 'WPM Payment',
                    user_id    => undef,
                    library_id => $borrower->branchcode,
                    type       => 'payment',
                    item_id    => $line->itemnumber
                }
            );
            my $this_line = Koha::Account::lines->search(
                { accountlines_id => $line->accountlines_id } );
            $credit->apply(
                { debits => $this_line, offset_type => 'Payment' } );

            # Link payment to wpm_transactions
            $sth->execute( $accountline_id, $transaction_id );

            # Renew any items as required
            my $item = Koha::Items->find( { itemnumber => $line->itemnumber } );

            # Renew if required
            if ( defined( $line->accounttype )
                && $line->accounttype eq "FU" )
            {
                if (
                    C4::Circulation::CheckIfIssuedToPatron(
                        $line->borrowernumber, $item->biblionumber
                    )
                  )
                {
                    my ( $can, $error ) =
                      C4::Circulation::CanBookBeRenewed( $line->borrowernumber,
                        $line->itemnumber, 0 );
                    if ($can) {
                        my $datedue =
                          C4::Circulation::AddRenewal( $line->borrowernumber,
                            $line->itemnumber );
                        C4::Circulation::_FixOverduesOnReturn(
                            $line->borrowernumber, $line->itemnumber );
                    }
                }
            }
        }
    }

    # Respond with OK
    my $response = new CGI;
    my $reply    = XML::LibXML::Document->new( '1.0', 'utf-8' );
    my $root     = $reply->createElement("wpmmessagevalidation");
    my $md5      = $xml->findvalue('/wpmpaymentrequest/@msgid');
    $root->setAttribute( 'msgid' => "$md5" );

    my $validation = $reply->createElement('validation');
    $validation->appendTextNode("1");
    $root->appendChild($validation);

    my $validationmessage = $reply->createElement('validationmessage');
    my $success           = XML::LibXML::CDATASection->new("Success");
    $validationmessage->appendChild($success);
    $root->appendChild($validationmessage);

    $reply->setDocumentElement($root);

    print CGI->header('text/xml');
    print $reply->toString();
}
else {
    # Update transaction status
    #
    # Respond OK

    my $reply = XML::LibXML::Document->new( '1.0', 'utf-8' );
    my $root  = $reply->createElement("wpmmessagevalidation");
    my $md5   = $xml->findvalue('/wpmpaymentrequest/@msgid');
    $root->setAttribute( 'msgid' => "$md5" );

    my $validation = $reply->createElement('validation');
    $validation->appendTextNode("1");
    $root->appendChild($validation);

    my $validationmessage = $reply->createElement('validationmessage');
    my $success           = XML::LibXML::CDATASection->new("Success");
    $validationmessage->appendChild($success);
    $root->appendChild($validationmessage);

    $reply->setDocumentElement($root);

    print CGI->header('text/xml');
    print $reply->toString();
}
