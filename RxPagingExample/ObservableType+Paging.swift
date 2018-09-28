//
//  ObservableType+Paging.swift
//  RxPagingExample
//
//  Created by Mikko Välimäki on 2018-09-29.
//  Copyright © 2018 Mikko. All rights reserved.
//

import Foundation
import RxSwift

extension ObservableType {

    public func mapWithPages<State>(page nextPage: @escaping (E, State?) -> Observable<State>,
                                    while hasNext: @escaping (State) -> Bool,
                                    when trigger: Observable<Void>) -> Observable<State> {

        let scheduler = MainScheduler()
        let replaySubject = ReplaySubject<(E, State?)>.create(bufferSize: 1)

        let inputFeedbackLoop = replaySubject
            .flatMapLatest { (query, state) -> Observable<State> in
                let r: Observable<State>
                if let state = state {
                    r = hasNext(state)
                        ? trigger.flatMap { nextPage(query, state) }
                        : Observable.empty()
                } else {
                    r = nextPage(query, nil)
                }
                return r
                    // observe on is here because results should be cancelable
                    .observeOn(scheduler.async)
                    // subscribe on is here because side-effects also need to be cancelable
                    // (smooths out any glitches caused by start-cancel immediately)
                    .subscribeOn(scheduler.async)
        }

        return self.flatMapLatest { (query) -> Observable<State> in
            return inputFeedbackLoop
                .do(onNext: { state in
                    replaySubject.onNext((query, state))
                }, onSubscribed: {
                    replaySubject.onNext((query, nil))
                })
        }
    }
}
