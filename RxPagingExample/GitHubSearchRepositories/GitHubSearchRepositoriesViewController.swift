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

    override func viewDidLoad() {
        super.viewDidLoad()

        let tableView: UITableView = self.tableView
        let loadNextPageTrigger: (Driver<GitHubSearchRepositoriesState>) -> Signal<()> =  { state in
            tableView.rx.contentOffset.asDriver()
                .withLatestFrom(state)
                .flatMap { state in
                    return tableView.isNearBottomEdge(edgeOffset: 20.0) && !state.shouldLoadNextPage
                        ? Signal.just(())
                        : Signal.empty()
            }
        }

        let activityIndicator = ActivityIndicator()

        let searchBar: UISearchBar = self.searchBar

        let state = githubSearchRepositories(
            searchText: searchBar.rx.text.orEmpty.changed.asSignal().throttle(0.3),
            loadNextPageTrigger: loadNextPageTrigger,
            performSearch: { URL in
                GitHubSearchRepositoriesAPI.sharedAPI.loadSearchURL(URL)
                    .trackActivity(activityIndicator)
            })

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
                if searchBar.isFirstResponder {
                    _ = searchBar.resignFirstResponder()
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

    func openURL(_ url: URL) {
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }

    func showAlert(_ message: String) {
        let alert = UIAlertController(title: "RxExample", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default, handler: nil))
        self.present(alert, animated: true, completion: nil)
    }
}

