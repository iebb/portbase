import XCTest
@testable import PortSQL

final class SQLSafetyServiceTests: XCTestCase {
    func testReadOnlyAllowsSelectShowAndExplainStatements() {
        XCTAssertNil(SQLSafetyService.assessment(for: "SELECT * FROM users LIMIT 5", readOnly: true))
        XCTAssertNil(SQLSafetyService.assessment(for: "SHOW TABLES", readOnly: true))
        XCTAssertNil(SQLSafetyService.assessment(for: "EXPLAIN SELECT * FROM users", readOnly: true))
    }

    func testReadOnlyBlocksWriteStatements() {
        let assessment = SQLSafetyService.assessment(
            for: "INSERT INTO users(name) VALUES ('Tokyo')",
            readOnly: true
        )

        XCTAssertEqual(assessment?.title, "Read-only connection")
        XCTAssertEqual(assessment?.blocksExecution, true)
        XCTAssertEqual(assessment?.requiresConfirmation, false)
    }

    func testDeleteAndUpdateWithoutWhereRequireConfirmation() {
        let deleteAssessment = SQLSafetyService.assessment(for: "DELETE FROM users", readOnly: false)
        let updateAssessment = SQLSafetyService.assessment(for: "UPDATE users SET active = false", readOnly: false)

        XCTAssertEqual(deleteAssessment?.isDestructive, true, "DELETE without WHERE gets the destructive confirmation")
        XCTAssertEqual(deleteAssessment?.requiresConfirmation, true)
        XCTAssertEqual(updateAssessment?.title, "Confirm UPDATE")
        XCTAssertEqual(updateAssessment?.requiresConfirmation, true)
    }

    func testWhereInsideStringLiteralDoesNotBypassUpdateWarning() {
        let assessment = SQLSafetyService.assessment(
            for: "UPDATE users SET note = 'WHERE should not count'",
            readOnly: false
        )

        XCTAssertEqual(assessment?.title, "Confirm UPDATE")
    }

    func testWithStatementContainingMutationIsNotReadOnly() {
        let assessment = SQLSafetyService.assessment(
            for: "WITH deleted AS (DELETE FROM sessions RETURNING id) SELECT * FROM deleted",
            readOnly: true
        )

        XCTAssertEqual(assessment?.title, "Read-only connection")
        XCTAssertEqual(assessment?.blocksExecution, true)
    }

    func testCommentsDoNotCreateFalseWhereMatches() {
        let assessment = SQLSafetyService.assessment(
            for: "DELETE FROM audit_log -- WHERE id = 1",
            readOnly: false
        )

        XCTAssertEqual(assessment?.isDestructive, true, "DELETE without WHERE gets the destructive confirmation")
    }

    func testMySQLHashCommentDoesNotCreateFalseWhereMatch() {
        let assessment = SQLSafetyService.assessment(
            for: "DELETE FROM audit_log # WHERE id = 1",
            readOnly: false,
            engine: .mysql
        )

        XCTAssertEqual(assessment?.isDestructive, true, "DELETE without WHERE gets the destructive confirmation")
        XCTAssertEqual(assessment?.requiresConfirmation, true)
    }

    func testBackslashEscapedQuoteCannotHideMissingWhere() {
        let assessment = SQLSafetyService.assessment(
            for: #"UPDATE users SET note = 'x\' WHERE fake'"#,
            readOnly: false,
            engine: .mysql
        )

        XCTAssertEqual(assessment?.title, "Confirm UPDATE")
    }

    func testWhereInsideSubqueryDoesNotBypassTopLevelUpdateWarning() {
        let assessment = SQLSafetyService.assessment(
            for: "UPDATE users SET score = (SELECT max(score) FROM archive WHERE active = true)",
            readOnly: false
        )

        XCTAssertEqual(assessment?.title, "Confirm UPDATE")
    }

    func testPostgresDollarQuotedWhereDoesNotBypassTopLevelUpdateWarning() {
        let assessment = SQLSafetyService.assessment(
            for: "UPDATE users SET note = $$WHERE$$",
            readOnly: false
        )

        XCTAssertEqual(assessment?.title, "Confirm UPDATE")
    }

    func testWrappedTopLevelWritesAreAssessed() {
        let cteUpdate = SQLSafetyService.assessment(
            for: "WITH candidate AS (SELECT 1) UPDATE users SET active = false",
            readOnly: false
        )
        let analyzedUpdate = SQLSafetyService.assessment(
            for: "EXPLAIN ANALYZE UPDATE users SET active = false",
            readOnly: false
        )

        XCTAssertEqual(cteUpdate?.title, "Confirm UPDATE")
        XCTAssertTrue(cteUpdate?.requiresConfirmation == true)
        XCTAssertEqual(analyzedUpdate?.title, "Confirm UPDATE")
        XCTAssertTrue(analyzedUpdate?.requiresConfirmation == true)
    }

    func testMergeIsMutatingAndRequiresConfirmation() {
        let sql = "MERGE INTO target USING source ON target.id = source.id WHEN MATCHED THEN UPDATE SET value = source.value"
        let assessment = SQLSafetyService.assessment(for: sql, readOnly: false)

        XCTAssertFalse(SQLSafetyService.isReadOnlySQL(sql))
        XCTAssertEqual(assessment?.title, "Confirm write")
        XCTAssertTrue(assessment?.requiresConfirmation == true)
    }

    func testPostgresJSONPathOperatorDoesNotHideFollowingMutation() {
        let sql = "SELECT payload #>> '{profile,name}' FROM users; UPDATE users SET active = false"

        XCTAssertFalse(SQLSafetyService.isReadOnlySQL(sql))
        XCTAssertEqual(
            SQLSafetyService.assessment(for: sql, readOnly: false)?.title,
            "Confirm UPDATE"
        )
    }

    func testWriteWithWhereStillRequiresConfirmation() {
        let assessment = SQLSafetyService.assessment(
            for: "UPDATE users SET active = false WHERE id = 1",
            readOnly: false
        )

        XCTAssertEqual(assessment?.title, "Confirm write")
        XCTAssertTrue(assessment?.requiresConfirmation == true)
    }

    func testSelectIntoIsNotReadOnly() {
        let postgres = "SELECT id, name INTO archived_users FROM users"
        let mysql = "SELECT payload FROM audit INTO OUTFILE '/tmp/audit.csv'"

        XCTAssertFalse(SQLSafetyService.isReadOnlySQL(postgres))
        XCTAssertFalse(SQLSafetyService.isReadOnlySQL(mysql, engine: .mysql))
        XCTAssertEqual(SQLSafetyService.assessment(for: postgres, readOnly: false)?.title, "Confirm write")
        XCTAssertEqual(SQLSafetyService.assessment(for: mysql, readOnly: false, engine: .mysql)?.title, "Confirm write")
    }

    func testMySQLExecutableCommentCannotHideMutation() {
        let assessment = SQLSafetyService.assessment(
            for: "/*!50700 DELETE FROM sessions */",
            readOnly: true,
            engine: .mysql
        )

        XCTAssertEqual(assessment?.title, "Read-only connection")
        XCTAssertEqual(assessment?.blocksExecution, true)
        XCTAssertFalse(SQLSafetyService.isReadOnlySQL("/*! UPDATE users SET admin = 1 */", engine: .mysql))
    }

    func testMariaDBExecutableCommentCannotHideMutation() {
        let sql = "/*M!100100 DELETE FROM sessions */"
        let assessment = SQLSafetyService.assessment(for: sql, readOnly: false, engine: .mysql)

        XCTAssertFalse(SQLSafetyService.isReadOnlySQL(sql, engine: .mysql))
        XCTAssertEqual(assessment?.isDestructive, true, "DELETE without WHERE gets the destructive confirmation")
        XCTAssertTrue(assessment?.requiresConfirmation == true)
    }

    func testEngineSpecificOperatorsAndDashCommentsCannotHideWrites() {
        let postgres = "SELECT payload #- '{a}' INTO archived FROM users"
        let mysql = "SELECT 1--1 INTO OUTFILE '/tmp/x'"

        XCTAssertFalse(SQLSafetyService.isReadOnlySQL(postgres, engine: .postgresql))
        XCTAssertEqual(
            SQLSafetyService.assessment(for: postgres, readOnly: false, engine: .postgresql)?.title,
            "Confirm write"
        )
        XCTAssertFalse(SQLSafetyService.isReadOnlySQL(mysql, engine: .mysql))
        XCTAssertEqual(
            SQLSafetyService.assessment(for: mysql, readOnly: false, engine: .mysql)?.title,
            "Confirm write"
        )
    }

    func testEngineSpecificQuotedSyntaxCannotHideSelectInto() {
        let postgres = #"SELECT 'x\' INTO archived FROM users"#
        let mysql = "SELECT $x$ INTO OUTFILE '/tmp/$x$'"

        XCTAssertFalse(SQLSafetyService.isReadOnlySQL(postgres, engine: .postgresql))
        XCTAssertEqual(
            SQLSafetyService.assessment(for: postgres, readOnly: false, engine: .postgresql)?.title,
            "Confirm write"
        )
        XCTAssertFalse(SQLSafetyService.isReadOnlySQL(mysql, engine: .mysql))
        XCTAssertEqual(
            SQLSafetyService.assessment(for: mysql, readOnly: false, engine: .mysql)?.title,
            "Confirm write"
        )
    }

    func testMySQLBackslashModeAmbiguityFailsClosed() {
        let sql = #"SELECT 'x\' INTO OUTFILE '/tmp/x'"#

        XCTAssertFalse(SQLSafetyService.isReadOnlySQL(sql, engine: .mysql))
        XCTAssertEqual(
            SQLSafetyService.assessment(for: sql, readOnly: false, engine: .mysql)?.title,
            "Confirm write"
        )
    }

    func testPostgresEscapeStringCannotHideSelectInto() {
        let sql = #"SELECT E'x\'foo' INTO archived FROM users"#

        XCTAssertFalse(SQLSafetyService.isReadOnlySQL(sql, engine: .postgresql))
        XCTAssertEqual(
            SQLSafetyService.assessment(for: sql, readOnly: false, engine: .postgresql)?.title,
            "Confirm write"
        )
    }

    func testExplainAnalyzeMutationIsRejected() {
        XCTAssertFalse(SQLSafetyService.isReadOnlySQL("EXPLAIN ANALYZE DELETE FROM sessions"))
        XCTAssertNil(SQLSafetyService.explainQuery(for: "DELETE FROM sessions WHERE id = 1"))
        XCTAssertEqual(
            SQLSafetyService.explainQuery(for: "SELECT * FROM sessions"),
            "EXPLAIN SELECT * FROM sessions"
        )
    }
}
