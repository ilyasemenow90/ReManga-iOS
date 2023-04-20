//
//  ReMangaApi.swift
//  ReManga
//
//  Created by Даниил Виноградов on 12.04.2023.
//

import MvvmFoundation
import Kingfisher
import RxRelay
import RxSwift

class ReMangaApi: ApiProtocol {
    private let disposeBag = DisposeBag()
    static let imgPath: String = "https://remanga.org/"
    var authToken = BehaviorRelay<String?>(value: nil)

    var kfAuthModifier: Kingfisher.AnyModifier {
        AnyModifier { [weak self] request in
            var r = request
            if let authToken = self?.authToken.value {
                r.addValue("bearer \(authToken)", forHTTPHeaderField: "Authorization")
            }
            r.addValue("https://remanga.org/", forHTTPHeaderField: "referer")
            return r
        }
    }

    func makeRequest(_ url: String) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        if let authToken = authToken.value {
            request.addValue("bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    var urlSession: URLSession {
        let session = URLSession.shared
        return session
    }

    init() {
        authToken.accept(UserDefaults.standard.string(forKey: "ReAuthToken"))
        bind(in: disposeBag) {
            authToken.bind { token in
                UserDefaults.standard.set(token, forKey: "ReAuthToken")
            }
        }
    }
    
    func fetchCatalog(page: Int, filters: [ApiMangaTag] = []) async throws -> [ApiMangaModel] {
        var tags = ""
        for filter in filters {
            switch filter.kind {
            case .tag:
                tags.append("&categories=\(filter.id)")
            case .type:
                tags.append("&types=\(filter.id)")
            case .genre:
                tags.append("&genres=\(filter.id)")
            }
        }

        let url = "https://api.remanga.org/api/search/catalog/?count=30&ordering=-rating&page=\(page)\(tags)"
        let (result, _) = try await urlSession.data(for: makeRequest(url))
        let model = try JSONDecoder().decode(ReMangaApiMangaCatalogResult.self, from: result)

        return await MainActor.run { model.content.map { ApiMangaModel(from: $0) } }
    }

    func fetchSearch(query: String, page: Int) async throws -> [ApiMangaModel] {
        let _query = query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
        let url = "https://api.remanga.org/api/search/?query=\(_query)&count=30&field=titles&page=\(page)"
        let (result, _) = try await urlSession.data(for: makeRequest(url))
        let model = try JSONDecoder().decode(ReMangaApiMangaCatalogResult.self, from: result)

        return await MainActor.run { model.content.map { ApiMangaModel(from: $0) } }
    }

    func fetchDetails(id: String) async throws -> ApiMangaModel {
        let url = "https://api.remanga.org/api/titles/\(id)"
        let req = makeRequest(url)
        let (result, resp) = try await urlSession.data(for: req)
        print(String.init(data: result, encoding: .utf8)!)
        let model = try JSONDecoder().decode(ReMangaApiDetailsResult.self, from: result)

        return await MainActor.run { ApiMangaModel(from: model.content) }
    }

    func fetchTitleChapters(branch: String, count: Int, page: Int) async throws -> [ApiMangaChapterModel] {
        let url = "https://api.remanga.org/api/titles/chapters/?branch_id=\(branch)&ordering=-index&user_data=1&count=\(count)&page=\(page)"
        let (result, _) = try await urlSession.data(for: makeRequest(url))
        let model = try JSONDecoder().decode(ReMangaTitleChaptersResult.self, from: result)
        
        return model.content.map { .init(from: $0) }
    }

    func fetchChapter(id: String) async throws -> [ApiMangaChapterPageModel] {
        let url = "https://api.remanga.org/api/titles/chapters/\(id)/"
        let (result, _) = try await urlSession.data(for: makeRequest(url))
        let model = try JSONDecoder().decode(ReMangaChapterPagesResult.self, from: result)
        
        return model.content.pages.flatMap { $0 }.map { .init(from: $0) }
    }

    func fetchComments(id: String, count: Int, page: Int) async throws -> [ApiMangaCommentModel] {
        let url = "https://api.remanga.org/api/activity/comments/?title_id=\(id)&page=\(page)&ordering=-id&count=\(count)"
        let (result, _) = try await urlSession.data(for: makeRequest(url))
        let model = try JSONDecoder().decode(ReMangaCommentsResult.self, from: result)

        return model.content.compactMap { .init(from: $0) }
    }

    func fetchCommentsReplies(id: String, count: Int, page: Int) async throws -> [ApiMangaCommentModel] {
        let url = "https://api.remanga.org/api/activity/comments/?reply_to=\(id)&page=\(page)&ordering=-id&count=\(count)"
        let (result, _) = try await urlSession.data(for: makeRequest(url))
        let model = try JSONDecoder().decode(ReMangaCommentsResult.self, from: result)

        return model.content.compactMap { .init(from: $0) }
    }

    func markChapterRead(id: String) async throws {
        let url = "https://api.remanga.org/api/activity/views/"

        var request = makeRequest(url)
        request.httpMethod = "POST"
        request.httpBody = "{ \"chapter\": \(id) }".data(using: .utf8)
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")

        _ = try await urlSession.data(for: request)
    }

    func setChapterLike(id: String, _ value: Bool) async throws {
        guard value else { throw ApiMangaError.operationNotSupported(message: "Remove like is not supported by ReManga") }
        let url = "https://api.remanga.org/api/activity/votes/"

        var request = makeRequest(url)
        request.httpMethod = "POST"
        request.httpBody = "{ \"type\": 0, \"chapter\": \(id) }".data(using: .utf8)
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")

        _ = try await urlSession.data(for: request)
    }

    func buyChapter(id: String) async throws {

    }
    
    func markComment(id: String, _ value: Bool?) async throws -> Int {
        0
    }
}
