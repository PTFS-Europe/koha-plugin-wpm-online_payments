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

use Modern::Perl;

use CGI qw( -utf8 );

use C4::Context;
use C4::Circulation;
use Koha::Account;
use Koha::Account::Lines;
use Koha::Patrons;
use Koha::Plugin::Com::PTFSEurope::WPMPayments;

use XML::LibXML;
use Digest::MD5 qw(md5_hex);

my $debug = 0;

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

# Set the userenv
C4::Context->_new_userenv( 'PLUGIN_' . time() );
C4::Context->set_userenv(
    $borrower->borrowernumber, $borrower->userid,
    $borrower->cardnumber,     $borrower->firstname,
    $borrower->surname,        $borrower->branchcode,
    $borrower->flags,          undef,
    undef,                     undef,
    undef,
);

if ( $success eq '1' ) {

    $debug and warn "Recieved 'success' from WPM";

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

    # Make Payment
    my $lines = Koha::Account::Lines->search(
        { accountlines_id => { 'in' => \@accountline_ids } } )->as_list;
    my $account        = Koha::Account->new( { patron_id => $borrowernumber } );
    my $accountline_id = $account->pay(
        {
            amount     => $totalpaid,
            note       => 'WPM Payment',
            library_id => $borrower->branchcode,
            interface  => 'opac',
            lines => $lines,    # Arrayref of Koha::Account::Line objects to pay
            #payment_type => $payment_type,  # accounttype code
        }
    );
    $debug
      and warn "Payment of $totalpaid made against "
      . join( ', ', @accountline_ids );

    # Return signature of ->pay changed with version 20.05.00
    if ( $paymentHandler->_version_check('20.05.00') ) {
        $accountline_id = $accountline_id->{payment_id};
    }

    # Link payment to wpm_transactions
    my $dbh   = C4::Context->dbh;
    my $table = $paymentHandler->get_qualified_table_name('wpm_transactions');
    my $sth   = $dbh->prepare(
        "UPDATE $table SET accountline_id = ? WHERE transaction_id = ?");
    $sth->execute( $accountline_id, $transaction_id );
    $debug and warn "Update the original transaction";
    $debug
      and warn
"UPDATE $table SET accountline_id = $accountline_id WHERE transaction_id = $transaction_id;";

    # Renew any items as required
    unless ( $paymentHandler->_version_check('20.05.00') ) {
        for my $line ( @{$lines} ) {
            my $item = Koha::Items->find( { itemnumber => $line->itemnumber } );

            # Renew if required
            if ( $paymentHandler->_version_check('19.11.00') ) {
                if (   $line->debit_type_code eq "OVERDUE"
                    && $line->status ne "UNRETURNED" )
                {
                    if (
                        C4::Circulation::CheckIfIssuedToPatron(
                            $line->borrowernumber, $item->biblionumber
                        )
                      )
                    {
                        my ( $renew_ok, $error ) =
                          C4::Circulation::CanBookBeRenewed(
                            $line->borrowernumber, $line->itemnumber, 0 );
                        if ($renew_ok) {
                            C4::Circulation::AddRenewal( $line->borrowernumber,
                                $line->itemnumber );
                        }
                    }
                }
            }
            else {
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
                          C4::Circulation::CanBookBeRenewed(
                            $line->borrowernumber, $line->itemnumber, 0 );
                        if ($can) {

                            # Fix paid for fine before renewal to prevent
                            # call to _CalculateAndUpdateFine if
                            # CalculateFinesOnReturn is set.
                            C4::Circulation::_FixOverduesOnReturn(
                                $line->borrowernumber, $line->itemnumber );

                            # Renew the item
                            my $datedue =
                              C4::Circulation::AddRenewal(
                                $line->borrowernumber, $line->itemnumber );

                            $debug
                              and warn
                              "Renewal of $line->itemnumber successful";
                        }
                        else {
                            $debug
                              and warn "Renewal of $line->itemnumber blocked";
                        }
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
