// Copyright (c) 2019 The DAML Authors. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

package com.digitalasset.http
package query

import json.JsonProtocol.LfValueCodec.{apiValueToJsValue, jsValueToApiValue}
import com.digitalasset.daml.lf.data.{Decimal, ImmArray, Numeric, Ref, SortedLookupList, Time}
import ImmArray.ImmArraySeq
import com.digitalasset.daml.lf.iface
import com.digitalasset.daml.lf.value.{Value => V}
import com.digitalasset.daml.lf.value.TypedValueGenerators.{genAddend, ValueAddend => VA}

import org.scalacheck.{Arbitrary, Gen}
import org.scalactic.source
import org.scalatest.prop.{GeneratorDrivenPropertyChecks, TableDrivenPropertyChecks}
import org.scalatest.{Matchers, WordSpec}
import spray.json._

@SuppressWarnings(Array("org.wartremover.warts.Any"))
class ValuePredicateTest
    extends WordSpec
    with Matchers
    with GeneratorDrivenPropertyChecks
    with TableDrivenPropertyChecks {
  type Cid = V.AbsoluteContractId
  private[this] val genCid = Gen.zip(Gen.alphaChar, Gen.alphaStr) map {
    case (h, t) => V.AbsoluteContractId(Ref.ContractIdString assertFromString (h +: t))
  }

  private[this] val dummyId = Ref.Identifier(
    Ref.PackageId assertFromString "dummy-package-id",
    Ref.QualifiedName assertFromString "Foo:Bar")
  private[this] val dummyFieldName = Ref.Name assertFromString "foo"
  private[this] val dummyTypeCon = iface.TypeCon(iface.TypeConName(dummyId), ImmArraySeq.empty)
  private[this] def valueAndTypeInObject(
      v: V[Cid],
      ty: iface.Type): (V[Cid], ValuePredicate.TypeLookup) =
    (
      V.ValueRecord(Some(dummyId), ImmArray((Some(dummyFieldName), v))),
      Map(
        dummyId -> iface
          .DefDataType(ImmArraySeq.empty, iface.Record(ImmArraySeq((dummyFieldName, ty))))).lift)

  "fromJsObject" should {
    def c(query: String, ty: VA)(expected: ty.Inj[Cid], shouldMatch: Boolean)(
        implicit pos: source.Position) =
      (pos.lineNumber, query.parseJson, ty, ty.inj(expected), shouldMatch)

    object VAs {
      val oi = VA.optional(VA.int64)
      val ooi = VA.optional(oi)
      val oooi = VA.optional(ooi)
    }

    val literals = Table(
      ("query or json", "type"),
      ("\"foo\"", VA.text),
      ("42", VA.int64),
      ("111.11", VA.numeric(Numeric.Scale assertFromInt 10)),
      ("[1, 2, 3]", VA.list(VA.int64)),
      ("null", VAs.oi),
      ("42", VAs.oi),
      ("null", VAs.ooi),
      ("[]", VAs.ooi),
      ("[42]", VAs.ooi),
      ("null", VAs.oooi),
      ("[]", VAs.oooi),
      ("[[]]", VAs.oooi),
      ("[[42]]", VAs.oooi),
    )

    val excl4143 = """{"%gt": 41, "%lt": 43}"""
    val incl42 = """{"%gte": 42, "%lte": 42}"""
    val VAtestNumeric = VA.numeric(Decimal.scale)

    val successes = Table(
      ("line#", "query", "type", "expected", "should match?"),
      c("\"foo\"", VA.text)("foo", true),
      c("\"foo\"", VA.text)("bar", false),
      c("42", VA.int64)(42, true),
      c("42", VA.int64)(43, false),
      c(excl4143, VA.int64)(42, true),
      c(excl4143, VA.int64)(41, false),
      c(excl4143, VA.int64)(43, false),
      c(incl42, VA.int64)(42, true),
      c(incl42, VA.int64)(41, false),
      c(incl42, VA.int64)(43, false),
      c(excl4143, VAtestNumeric)(Numeric assertFromString "42.", true),
      c(excl4143, VAtestNumeric)(Numeric assertFromString "41.", false),
      c(excl4143, VAtestNumeric)(Numeric assertFromString "43.", false),
      c(incl42, VAtestNumeric)(Numeric assertFromString "42.", true),
      c(incl42, VAtestNumeric)(Numeric assertFromString "41.", false),
      c(incl42, VAtestNumeric)(Numeric assertFromString "43.", false),
      c("""{"%lte": 42}""", VA.int64)(42, true),
      c("""{"%lte": 42}""", VA.int64)(43, false),
      c("""{"%gte": 42}""", VA.int64)(42, true),
      c("""{"%gte": 42}""", VA.int64)(41, false),
      c("""{"%lt": 42}""", VA.int64)(41, true),
      c("""{"%lt": 42}""", VA.int64)(42, false),
      c("""{"%gt": 42}""", VA.int64)(43, true),
      c("""{"%gt": 42}""", VA.int64)(42, false),
      c("""{"%gt": "bar", "%lt": "foo"}""", VA.text)("baz", true),
      c("""{"%gte": "1980-01-01", "%lt": "2000-01-01"}""", VA.date)(
        Time.Date assertFromString "1986-06-21",
        true),
      c("""{"%gte": "1980-01-01T00:00:00Z", "%lt": "2000-01-01T00:00:00Z"}""", VA.timestamp)(
        Time.Timestamp assertFromString "1986-06-21T00:00:00Z",
        true),
      c("""{"a": 1, "b": 2}""", VA.map(VA.int64))(SortedLookupList(Map("a" -> 1, "b" -> 2)), true),
      c("""{"a": 1, "b": 2}""", VA.map(VA.int64))(SortedLookupList(Map("a" -> 1, "c" -> 2)), false),
      c("""{"a": 1, "b": 2}""", VA.map(VA.int64))(SortedLookupList(Map()), false),
      c("[1, 2, 3]", VA.list(VA.int64))(Vector(1, 2, 3), true),
      c("[1, 2, 3]", VA.list(VA.int64))(Vector(3, 2, 1), false),
    )

    "treat literals exactly like ApiCodecCompressed" in forAll(literals) { (queryOrJson, va) =>
      val qj = queryOrJson.parseJson
      val accVal = jsValueToApiValue(qj, va.t, (_: Any) => None)
      val (wrappedExpected, defs) = valueAndTypeInObject(accVal, va.t)
      val vp = ValuePredicate.fromJsObject(Map((dummyFieldName: String) -> qj), dummyTypeCon, defs)
      vp.toFunPredicate(wrappedExpected) shouldBe true
    }

    "examine simple fields literally" in forAll(successes) {
      (_, query, va, expected, shouldMatch) =>
        val (wrappedExpected, defs) = valueAndTypeInObject(expected, va.t)
        val vp = ValuePredicate.fromJsObject(
          Map((dummyFieldName: String) -> query),
          dummyTypeCon,
          defs
        )
        vp.toFunPredicate(wrappedExpected) shouldBe shouldMatch
    }

    "examine all sorts of primitives literally" in forAll(genAddend, minSuccessful(100)) { va =>
      import va.injshrink
      implicit val arbInj: Arbitrary[va.Inj[Cid]] = va.injarb(Arbitrary(genCid))
      forAll(minSuccessful(20)) { v: va.Inj[Cid] =>
        val expected = va.inj(v)
        val (wrappedExpected, defs) = valueAndTypeInObject(expected, va.t)
        val query = apiValueToJsValue(expected)
        val vp =
          ValuePredicate.fromJsObject(Map((dummyFieldName: String) -> query), dummyTypeCon, defs)
        vp.toFunPredicate(wrappedExpected) shouldBe true
      }
    }
  }
}
