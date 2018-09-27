//
//  GitHubSearchRepositories.swift
//  RxExample
//
//  Created by Krunoslav Zaher on 3/18/17.
//  Copyright © 2017 Krunoslav Zaher. All rights reserved.
//

enum GitHubCommand {
    case changeSearch(text: String)
    case loadMoreItems
    case gitHubResponseReceived(SearchRepositoriesResponse)
}

struct GitHubSearchRepositoriesState {
    // control
    var searchText: String
    var shouldLoadNextPage: Bool
    var repositories: [Repository] // Version is an optimization. When something unrelated changes, we don't want to reload table view.
    var nextURL: URL?
    var failure: GitHubServiceError?

    init(searchText: String) {
        self.searchText = searchText
        shouldLoadNextPage = true
        repositories = []
        nextURL = URL(string: "https://api.github.com/search/repositories?q=\(searchText.URLEscaped)")
        failure = nil
    }
}

extension GitHubSearchRepositoriesState {
    static let initial = GitHubSearchRepositoriesState(searchText: "")

    static func reduce(state: GitHubSearchRepositoriesState, command: GitHubCommand) -> GitHubSearchRepositoriesState {
        switch command {
        case .changeSearch(let text):
            return GitHubSearchRepositoriesState(searchText: text).mutateOne { $0.failure = state.failure }
        case .gitHubResponseReceived(let result):
            switch result {
            case let .success((repositories, nextURL)):
                return state.mutate {
                    $0.repositories = $0.repositories + repositories
                    $0.shouldLoadNextPage = false
                    $0.nextURL = nextURL
                    $0.failure = nil
                }
            case let .failure(error):
                return state.mutateOne { $0.failure = error }
            }
        case .loadMoreItems:
            return state.mutate {
                if $0.failure == nil {
                    $0.shouldLoadNextPage = true
                }
            }
        }
    }
}

import RxSwift
import RxCocoa

struct GithubQuery: Equatable {
    let searchText: String;
    let shouldLoadNextPage: Bool;
    let nextURL: URL?
}

/**
 This method contains the gist of paginated GitHub search.
 
 */
/**
 This method contains the gist of paginated GitHub search.

 */
func githubSearchRepositories(
    searchText: Signal<String>,
    loadNextPageTrigger: @escaping (Driver<GitHubSearchRepositoriesState>) -> Signal<()>,
    performSearch: @escaping (URL) -> Observable<SearchRepositoriesResponse>
    ) -> Driver<GitHubSearchRepositoriesState> {

    let scheduler = MainScheduler()
    let replaySubject = ReplaySubject<GitHubSearchRepositoriesState>.create(bufferSize: 1)

    let searchPerformerFeedback: (Driver<GitHubSearchRepositoriesState>) -> Signal<GitHubCommand> = { state in
        return state.asObservable().map { state in
            GithubQuery(searchText: state.searchText, shouldLoadNextPage: state.shouldLoadNextPage, nextURL: state.nextURL)
            }
            .distinctUntilChanged()
            .flatMapLatest { (query: GithubQuery) -> Observable<GitHubCommand> in

                let effects: (GithubQuery) -> Signal<GitHubCommand> = { query in
                    if !query.shouldLoadNextPage {
                        return Signal.empty()
                    }

                    if query.searchText.isEmpty {
                        return Signal.just(GitHubCommand.gitHubResponseReceived(.success((repositories: [], nextURL: nil))))
                    }

                    guard let nextURL = query.nextURL else {
                        return Signal.empty()
                    }

                    return performSearch(nextURL)
                        .asSignal(onErrorJustReturn: .failure(GitHubServiceError.networkError))
                        .map(GitHubCommand.gitHubResponseReceived)
                }

                return effects(query)
                    .asObservable()
                    // observe on is here because results should be cancelable
                    .observeOn(scheduler.async)
                    // subscribe on is here because side-effects also need to be cancelable
                    // (smooths out any glitches caused by start-cancel immediately)
                    .subscribeOn(scheduler.async)
            }
            .asSignal(onErrorSignalWith: .empty())
    }

    // this is degenerated feedback loop that doesn't depend on output state
    let inputFeedbackLoop: (Driver<GitHubSearchRepositoriesState>) -> Signal<GitHubCommand> = { state in
        let loadNextPage = loadNextPageTrigger(state).map { _ in GitHubCommand.loadMoreItems }
        let searchText = searchText.map(GitHubCommand.changeSearch)

        return Signal.merge(loadNextPage, searchText)
    }

    // Create a system with two feedback loops that drive the system
    // * one that tries to load new pages when necessary
    // * one that sends commands from user input
    let initialState = GitHubSearchRepositoriesState.initial
    let reduce = GitHubSearchRepositoriesState.reduce
    let feedbacks = [searchPerformerFeedback, inputFeedbackLoop]

    let observableFeedbacks = feedbacks.map { f -> Observable<GitHubCommand> in
        return f(replaySubject.asDriver(onErrorDriveWith: Driver<GitHubSearchRepositoriesState>.empty())).asObservable()
    }

    return Observable.merge(observableFeedbacks)
        .observeOn(CurrentThreadScheduler.instance)
        .scan(initialState, accumulator: reduce)
        .do(onNext: { output in
            replaySubject.onNext(output)
        }, onSubscribed: {
            replaySubject.onNext(initialState)
        })
        //.subscribeOn(scheduler)
        .startWith(initialState)
        //.observeOn(scheduler)

        .asDriver(onErrorDriveWith: .empty())
}

extension GitHubSearchRepositoriesState {
    var isOffline: Bool {
        guard let failure = self.failure else {
            return false
        }

        if case .offline = failure {
            return true
        }
        else {
            return false
        }
    }

    var isLimitExceeded: Bool {
        guard let failure = self.failure else {
            return false
        }

        if case .githubLimitReached = failure {
            return true
        }
        else {
            return false
        }
    }
}

extension GitHubSearchRepositoriesState: Mutable {

}

// MARK: ---

extension ImmediateSchedulerType {
    var async: ImmediateSchedulerType {
        // This is a hack because of reentrancy. We need to make sure events are being sent async.
        // In case MainScheduler is being used MainScheduler.asyncInstance is used to make sure state is modified async.
        // If there is some unknown scheduler instance (like TestScheduler), just use it.
        return (self as? MainScheduler).map { _ in MainScheduler.asyncInstance } ?? self
    }
}

func exampleError(_ error: String, location: String = "\(#file):\(#line)") -> NSError {
    return NSError(domain: "ExampleError", code: -1, userInfo: [NSLocalizedDescriptionKey: "\(location): \(error)"])
}
