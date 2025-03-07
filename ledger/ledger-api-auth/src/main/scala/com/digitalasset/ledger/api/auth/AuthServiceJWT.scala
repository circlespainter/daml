// Copyright (c) 2019 The DAML Authors. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

package com.digitalasset.ledger.api.auth

import java.util.concurrent.{CompletableFuture, CompletionStage}

import com.digitalasset.daml.lf.data.Ref
import com.digitalasset.jwt.JwtVerifier
import com.digitalasset.ledger.api.auth.AuthServiceJWT.Error
import io.grpc.Metadata
import org.slf4j.{Logger, LoggerFactory}
import spray.json._

import scala.collection.mutable.ListBuffer
import scala.util.Try

/** An AuthService that reads a JWT token from a `Authorization: Bearer` HTTP header.
  * The token is expected to use the format as defined in [[AuthServiceJWTPayload]]:
  */
class AuthServiceJWT(verifier: JwtVerifier) extends AuthService {

  protected val logger: Logger = LoggerFactory.getLogger(AuthServiceJWT.getClass)

  override def decodeMetadata(headers: Metadata): CompletionStage[Claims] = {
    decodeAndParse(headers).fold(
      error => {
        logger.warn("Authorization error: " + error.message)
        CompletableFuture.completedFuture(Claims.empty)
      },
      token => CompletableFuture.completedFuture(payloadToClaims(token))
    )
  }

  private[this] def parsePayload(jwtPayload: String): Either[Error, AuthServiceJWTPayload] = {
    import AuthServiceJWTCodec.JsonImplicits._
    Try(JsonParser(jwtPayload).convertTo[AuthServiceJWTPayload]).toEither.left.map(t =>
      Error("Could not parse JWT token: " + t.getMessage))
  }

  private[this] def decodeAndParse(headers: Metadata): Either[Error, AuthServiceJWTPayload] = {
    val bearerTokenRegex = "Bearer (.*)".r

    for {
      headerValue <- Option
        .apply(headers.get(AuthServiceJWT.AUTHORIZATION_KEY))
        .toRight(Error("Authorization header not found"))
      token <- bearerTokenRegex
        .findFirstMatchIn(headerValue)
        .map(_.group(1))
        .toRight(Error("Authorization header does not use Bearer format"))
      decoded <- verifier
        .verify(com.digitalasset.jwt.domain.Jwt(token))
        .toEither
        .left
        .map(e => Error("Could not verify JWT token: " + e.message))
      parsed <- parsePayload(decoded.payload)
    } yield parsed
  }

  private[this] def payloadToClaims(payload: AuthServiceJWTPayload): Claims = {
    val claims = ListBuffer[Claim]()

    // Any valid token authorizes the user to use public services
    claims.append(ClaimPublic)

    if (payload.admin)
      claims.append(ClaimAdmin)

    payload.actAs
      .foreach(party => claims.append(ClaimActAsParty(Ref.Party.assertFromString(party))))

    Claims(claims.toList, payload.exp)
  }
}

object AuthServiceJWT {
  final case class Error(message: String)

  val AUTHORIZATION_KEY: Metadata.Key[String] =
    Metadata.Key.of("Authorization", Metadata.ASCII_STRING_MARSHALLER)

  def apply(verifier: com.auth0.jwt.interfaces.JWTVerifier) =
    new AuthServiceJWT(new JwtVerifier(verifier))

  def apply(verifier: JwtVerifier) =
    new AuthServiceJWT(verifier)
}
