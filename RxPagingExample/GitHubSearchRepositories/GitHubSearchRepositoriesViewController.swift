//
//  GitHubSearchRepositoriesViewController.swift
//  RxExample
//
//  Created by Yoshinori Sano on 9/29/15.
//  Copyright © 2015 Krunoslav Zaher. All rights reserved.
//

import UIKit
import RxSwift
import RxCocoa
import RxDataSources

extension UIScrollView {
    func  isNearBottomEdge(edgeOffset: CGFloat = 20.0) -> Bool {
        return self.contentOffset.y + self.frame.size.height + edgeOffset > self.contentSize.height
    }
}

typealias Query = String

class GitHubSearchRepositoriesViewController: ViewController, UITableViewDelegate {
    static let startLoadingOffset: CGFloat = 20.0

    private let disposeBag = DisposeBag()

    @IBOutlet weak var tableView: UITableView!
    @IBOutlet weak var searchBar: UISearchBar!

    let dataSource = RxTableViewSectionedReloadDataSource<SectionModel<String, Repository>>(
        configureCell: { (_, tv, ip, repository: Repository) in
            let cell = tv.dequeueReusableCell(withIdentifier: "Cell")!
            cell.textLabel?.text = repository.name
            cell.detailTextLabel?.text = repository.url.absoluteString
            return cell
        },
        titleForHeaderInSection: { dataSource, sectionIndex in
            let section = dataSource[sectionIndex]
            return section.items.count > 0 ? "Repositories (\(section.items.count))" : "No repositories found"
        }
    )

    let activityIndicator = ActivityIndicator()

    override func viewDidLoad() {
        super.viewDidLoad()

        let search = searchBar.rx.text.orEmpty.changed
            .asObservable()
            .throttle(0.3, scheduler: MainScheduler.instance)
            .distinctUntilChanged()

        let trigger = tableView.rx.contentOffset.asObservable()
            .flatMap { state in
                return self.tableView.isNearBottomEdge(edgeOffset: 20.0)
                    ? Signal.just(())
                    : Signal.empty()
        }

        // CONS: State gets reset on new search
        let state = search
            .mapWithPages(page: self.search, while: { (s) -> Bool in
                return true
            }, when: trigger)
            .asDriver(onErrorDriveWith: .empty())

        state
            .map { $0.repositories }
            //.distinctUntilChanged()
            .map { [SectionModel(model: "Repositories", items: $0)] }
            .drive(tableView.rx.items(dataSource: dataSource))
            .disposed(by: disposeBag)

        tableView.rx.modelSelected(Repository.self)
            .subscribe(onNext: { repository in
                self.openURL(repository.url)
                //UIApplication.shared.openURL(repository.url)
            })
            .disposed(by: disposeBag)

        state
            .map { $0.isLimitExceeded }
            .distinctUntilChanged()
            .filter { $0 }
            .drive(onNext: { n in
                self.showAlert("Exceeded limit of 10 non authenticated requests per minute for GitHub API. Please wait a minute. :(\nhttps://developer.github.com/v3/#rate-limiting")
            })
            .disposed(by: disposeBag)

        tableView.rx.contentOffset
            .subscribe { _ in
                if self.searchBar.isFirstResponder {
                    _ = self.searchBar.resignFirstResponder()
                }
            }
            .disposed(by: disposeBag)

        // so normal delegate customization can also be used
        tableView.rx.setDelegate(self)
            .disposed(by: disposeBag)

        // activity indicator in status bar
        // {
        activityIndicator
            .drive(UIApplication.shared.rx.isNetworkActivityIndicatorVisible)
            .disposed(by: disposeBag)
        // }
    }

    // MARK: Table view delegate
    
    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        return 30
    }

    deinit {
        // I know, I know, this isn't a good place of truth, but it's no
        self.navigationController?.navigationBar.backgroundColor = nil
    }

    func search(query: Query, state: GitHubSearchRepositoriesState?) -> Observable<GitHubSearchRepositoriesState> {
        let state = state ?? GitHubSearchRepositoriesState(searchText: query)

        guard let nextURL = state.nextURL else {
            return Observable.just(state)
        }

        return GitHubSearchRepositoriesAPI.sharedAPI.loadSearchURL(nextURL)
            .trackActivity(activityIndicator)
            //.asSignal(onErrorJustReturn: .failure(GitHubServiceError.networkError))
            //.map(GitHubCommand.gitHubResponseReceived)
            .map { result -> GitHubSearchRepositoriesState in
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
        }
    }

    func openURL(_ url: URL) {
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }

    func showAlert(_ message: String) {
        let alert = UIAlertController(title: "RxExample", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default, handler: nil))
        self.present(alert, animated: true, completion: nil)
    }
}

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
                    r = trigger.flatMap {
                        nextPage(query, state)
                    }
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
