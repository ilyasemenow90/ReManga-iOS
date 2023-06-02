//
//  NewMangaApi.swift
//  ReManga
//
//  Created by Даниил Виноградов on 12.04.2023.
//

import Foundation
import Kingfisher
import MvvmFoundation
import RxRelay
import RxSwift

class NewMangaApi: ApiProtocol {
    static let imgPath: String = "https://img.newmanga.org/ProjectCard/webp/"
    let disposeBag = DisposeBag()
    let decoder = JSONDecoder()
    var authToken = BehaviorRelay<String?>(value: nil)

    let profile = BehaviorRelay<ApiMangaUserModel?>(value: nil)

    var kfAuthModifier: AnyModifier {
        AnyModifier { [weak self] request in
            var r = request
            if let authToken = self?.authToken.value {
                r.addValue("user_session=\(authToken)", forHTTPHeaderField: "cookie")
            }
            return r
        }
    }

    var name: String {
        "NewManga"
    }

    var logo: Image {
        .local(name: "NewManga")
    }

    var key: ContainerKey.Backend {
        .newmanga
    }

    init() {
        authToken.accept(UserDefaults.standard.string(forKey: "NewAuthToken"))
        bind(in: disposeBag) {
            authToken.bind { [unowned self] token in
                UserDefaults.standard.set(token, forKey: "NewAuthToken")
                Task { await refreshUserInfo() }
            }
        }

        Task { await refreshUserInfo() }
    }

    func makeRequest(_ url: String) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        if let authToken = authToken.value {
            request.addValue("user_session=\(authToken)", forHTTPHeaderField: "cookie")
        }
        return request
    }

    var urlSession: URLSession {
        let session = URLSession.shared
        if let authToken = authToken.value,
           let cookie = HTTPCookie(properties: [.name: "user_session", .value: authToken, .domain: ".newmanga.org"])
        {
            session.configuration.httpCookieStorage?.setCookie(cookie)
        }
        return session
    }

    func fetchCatalog(page: Int, filters: [ApiMangaTag] = []) async throws -> [ApiMangaModel] {
        try await fetchSearch(query: "", page: page, filters: filters)
    }

    func fetchSearch(query: String, page: Int) async throws -> [ApiMangaModel] {
        try await fetchSearch(query: query, page: page, filters: [])
    }

    func fetchSearch(query: String, page: Int, filters: [ApiMangaTag]) async throws -> [ApiMangaModel] {
        let url = "https://neo.newmanga.org/catalogue"

        var request = makeRequest(url)

        var body = NewMangaCatalogRequest()
        body.query = query
        body.pagination.page = page

        for filter in filters {
            switch filter.kind {
            case .tag:
                body.filter.tags.included.append(filter.name)
            case .type:
                body.filter.type.allowed.append(filter.name)
            case .genre:
                body.filter.genres.included.append(filter.name)
            }
        }

        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(body)

        let (result, _) = try await urlSession.data(for: request)
        let resModel = try decoder.decode(NewMangaCatalogResult.self, from: result)

        let mangas = resModel.result.hits?.compactMap { $0.document } ?? []

        return await MainActor.run { mangas.map { ApiMangaModel(from: $0) } }
    }

    func fetchDetails(id: String) async throws -> ApiMangaModel {
        let url = "https://api.newmanga.org/v2/projects/\(id)"
        let (result, _) = try await urlSession.data(for: makeRequest(url))
        let model = try JSONDecoder().decode(NewMangaDetailsResult.self, from: result)

        var res = await MainActor.run { ApiMangaModel(from: model) }

        do {
            let bookmarks = try await fetchBookmarkTypes()
            if let bookmark = model.bookmark?.type {
                res.bookmark = bookmarks.first(where: { $0.id == bookmark })
            }
        } catch {
            print(error)
        }

        return res
    }

    func fetchTitleChapters(branch: String, count: Int, page: Int) async throws -> [ApiMangaChapterModel] {
        let url = "https://api.newmanga.org/v3/branches/\(branch)/chapters/all"
        let (result, _) = try await urlSession.data(for: makeRequest(url))
        let model = try JSONDecoder().decode([NewMangaTitleChapterResultItem].self, from: result)

        return await MainActor.run { model.map { .init(from: $0) }.reversed() }
    }

    func fetchChapter(id: String) async throws -> [ApiMangaChapterPageModel] {
        let url = "https://api.newmanga.org/v3/chapters/\(id)/pages"
        let (result, _) = try await urlSession.data(for: makeRequest(url))
        let model = try JSONDecoder().decode(NewMangaChapterPagesResult.self, from: result)

        return await MainActor.run { model.getPages(chapter: id) }
    }

    func fetchComments(id: String, count: Int, page: Int) async throws -> [ApiMangaCommentModel] {
        let url = "https://api.newmanga.org/v2/projects/\(id)/comments?sort_by=new"
        let (result, _) = try await urlSession.data(for: makeRequest(url))
        let model = try JSONDecoder().decode(NewMangaTitleCommentsResult.self, from: result)

        return await MainActor.run { model.compactMap { .init(from: $0) } }
    }

    func fetchCommentsCount(id: String) async throws -> Int {
        throw ApiMangaError.operationNotSupported(message: "No need to fetch comments count on NewManga backend")
    }

    func fetchChapterComments(id: String, count: Int, page: Int) async throws -> [ApiMangaCommentModel] {
        []
    }

    func fetchChapterCommentsCount(id: String) async throws -> Int {
        0
    }

    func fetchCommentsReplies(id: String, count: Int, page: Int) async throws -> [ApiMangaCommentModel] {
        throw ApiMangaError.operationNotSupported(message: "No need to fetch comments replies on NewManga backend")
    }

    func markChapterRead(id: String) async throws {
        let url = "https://api.newmanga.org/v2/chapters/\(id)/read"
        var request = makeRequest(url)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        _ = try await urlSession.data(for: request)
    }

    func setChapterLike(id: String, _ value: Bool) async throws {
        let url = "https://api.newmanga.org/v2/chapters/\(id)/heart"

        var request = makeRequest(url)
        request.httpMethod = "POST"
        request.httpBody = "{ \"value\": \(value) }".data(using: .utf8)
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")

        let (result, _) = try await urlSession.data(for: request)
        _ = try JSONDecoder().decode(NewMangaLikeResultModel.self, from: result)
    }

    func buyChapter(id: String) async throws -> Bool {
        let url = "https://api.newmanga.org/v2/chapters/\(id)/buy"
        var request = makeRequest(url)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        _ = try await urlSession.data(for: request)
        return true
    }

    func markComment(id: String, _ value: Bool?) async throws -> Int {
        let url = "https://api.newmanga.org/v2/comments/\(id)/mark"

        var request = makeRequest(url)
        request.httpMethod = "POST"
        request.httpBody = "{ \"value\": \(String(describing: value?.toString ?? "null")) }".data(using: .utf8)
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")

        let (result, _) = try await urlSession.data(for: request)
        let model = try JSONDecoder().decode(NewMangaMarkCommentResultModel.self, from: result)

        return await MainActor.run { model.likes - model.dislikes }
    }

    func fetchUserInfo() async throws -> ApiMangaUserModel {
        let url = "https://api.newmanga.org/v2/user"
        let (result, response) = try await urlSession.data(for: makeRequest(url))
        if (response as? HTTPURLResponse)?.statusCode == 401 {
            authToken.accept(nil)
            throw ApiMangaError.unauthorized
        }

        let model = try JSONDecoder().decode(NewMangaUserResult.self, from: result)
        return .init(from: model)
    }

    func fetchBookmarkTypes() async throws -> [ApiMangaBookmarkModel] {
        let user = try await fetchUserInfo()

        let url = "https://api.newmanga.org/v2/users/\(user.id)/bookmarks/types"
        let (result, _) = try await urlSession.data(for: makeRequest(url))
        let model = try JSONDecoder().decode(NewMangaBookmarkTypesResult.self, from: result)

        let apiResults: [ApiMangaBookmarkModel] = model.compactMap { .init(id: $0.type, name: $0.type) }

        var defaultResults: [ApiMangaBookmarkModel] = ["Читаю", "Буду читать", "Прочитано", "Отложено", "Брошено", "Не интересно"].map { .init(id: $0, name: $0) }
        defaultResults.append(contentsOf: apiResults.filter { !defaultResults.contains($0) })

        return defaultResults
    }

    func setBookmark(title: String, bookmark: ApiMangaBookmarkModel?) async throws {
        let url = "https://api.newmanga.org/v2/projects/\(title)/bookmark"

        var request = makeRequest(url)
        if let bookmark {
            request.httpMethod = "POST"
            request.httpBody = "{ \"type\": \"\(bookmark.id)\" }".data(using: .utf8)
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        } else {
            request.httpMethod = "DELETE"
        }

        _ = try await urlSession.data(for: request)
    }

    func fetchBookmarks() async throws -> [ApiMangaModel] {
        let url = "https://api.newmanga.org/v2/user/bookmarks"
        let (result, _) = try await urlSession.data(for: makeRequest(url))
        let model = try JSONDecoder().decode(NewMangaBookmarksResult.self, from: result)

        return model.map { .init(from: $0) }
    }

    func deauth() async throws {
        authToken.accept(nil)
        profile.accept(nil)
    }
}
