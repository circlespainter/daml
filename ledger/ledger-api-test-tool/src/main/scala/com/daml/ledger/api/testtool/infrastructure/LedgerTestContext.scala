// Copyright (c) 2019 The DAML Authors. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

package com.daml.ledger.api.testtool.infrastructure

import com.daml.ledger.api.testtool.infrastructure.Allocation.{
  Participant,
  ParticipantAllocation,
  Participants
}
import com.daml.ledger.api.testtool.infrastructure.Eventually.eventually
import com.daml.ledger.api.testtool.infrastructure.participant.ParticipantTestContext
import com.digitalasset.ledger.client.binding.Primitive.Party

import scala.concurrent.{ExecutionContext, Future}

private[testtool] final class LedgerTestContext private[infrastructure] (
    participants: Vector[ParticipantTestContext])(implicit ec: ExecutionContext) {

  private[this] val participantsRing = Iterator.continually(participants).flatten

  /**
    * This allocates participants and a specified number of parties for each participant.
    *
    * e.g. `allocate(ParticipantAllocation(SingleParty, Parties(3), NoParties, TwoParties))`
    * will eventually return:
    *
    * {{{
    * Participants(
    *   Participant(alpha: ParticipantTestContext, alice: Party),
    *   Participant(beta: ParticipantTestContext, bob: Party, barbara: Party, bernard: Party),
    *   Participant(gamma: ParticipantTestContext),
    *   Participant(delta: ParticipantTestContext, doreen: Party, dan: Party),
    * )
    * }}}
    *
    * Each test allocates participants, then deconstructs the result and uses the various ledgers
    * and parties throughout the test.
    */
  def allocate(allocation: ParticipantAllocation): Future[Participants] =
    Future
      .sequence(allocation.partyCounts.map(partyCount => {
        val participant = nextParticipant()
        for {
          parties <- participant.allocateParties(partyCount.count)
          partiesSet = parties.toSet
          _ <- eventually(waitForParties(participant, partiesSet))
        } yield Participant(participant, parties: _*)
      }))
      .map(Participants(_: _*))

  private[this] def waitForParties(
      participant: ParticipantTestContext,
      expectedParties: Set[Party]): Future[Unit] = {
    Future
      .sequence(participants.map(otherParticipant => {
        otherParticipant
          .listParties()
          .map(actualParties => {
            assert(
              expectedParties.subsetOf(actualParties),
              s"Parties from $participant never appeared on $otherParticipant.")
          })
      }))
      .map(_ => ())
  }

  private[this] def nextParticipant(): ParticipantTestContext =
    participantsRing.synchronized {
      participantsRing.next()
    }
}
