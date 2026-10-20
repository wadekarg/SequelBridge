//
//  StatementSource.swift
//  SequelBridge
//
//  Whether a statement was typed by you: a Query-tab run marks itself (a task-local, so
//  every statement the engine logs during the run inherits it), and the Console tells
//  yours from the ones the app builds or reads on its own.
//

import Foundation

nonisolated enum StatementSource {
    @TaskLocal static var typedByYou = false
}
