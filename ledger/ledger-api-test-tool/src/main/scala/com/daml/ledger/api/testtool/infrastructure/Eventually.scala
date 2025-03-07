// Copyright (c) 2019 The DAML Authors. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

package com.daml.ledger.api.testtool.infrastructure

import scala.concurrent.duration.{Duration, DurationInt}
import scala.concurrent.{ExecutionContext, Future}

object Eventually {
  def eventually[A](
      runAssertion: => Future[A],
      attempts: Int = 10,
      firstWaitTime: Duration = 10.millis)(implicit ec: ExecutionContext): Future[A] =
    RetryStrategy.exponentialBackoff(attempts, firstWaitTime) { _ =>
      runAssertion
    }
}
