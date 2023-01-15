//
//  BaseTabbarVC.swift
//  ViFi
//
//  Created by Emre Büyüker on 15.01.2023.
//

import UIKit

class BaseTabbarVC: UITabBarController {

    var uniNameVariable: String = ""
    var facNameVariable: String = ""
    var depNameVariable: String = ""
    var lessonNameVariable: String = ""
    
    @IBOutlet weak var tabbarItem: UITabBar!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        tabbarItem.isUserInteractionEnabled = false
        
        _ = try? isUpdateAvailable { [weak self] isShowAlert, error in
            
            guard let self = self, error == nil, let isShowAlert = isShowAlert else { return }
            
            if isShowAlert {
                DispatchQueue.main.async {
                    let alert = UIAlertController(title: "Error", message: "Uygulama en güncel sürüme sahip değil lütfen uygulamayı güncelleyiniz.", preferredStyle: .alert)
                    self.present(alert, animated: true)
                }
            }
        }
    }
}

private extension BaseTabbarVC {
    func isUpdateAvailable(completion: @escaping (Bool?, Error?) -> Void) throws -> URLSessionDataTask {
        guard let info = Bundle.main.infoDictionary,
            let appVersion = info["CFBundleShortVersionString"] as? String,
            let identifier = info["CFBundleIdentifier"] as? String,
            let url = URL(string: "http://itunes.apple.com/lookup?bundleId=\(identifier)") else {
                throw VersionError.invalidBundleInfo
        }
            
        let request = URLRequest(url: url, cachePolicy: URLRequest.CachePolicy.reloadIgnoringLocalCacheData)
        
        let task = URLSession.shared.dataTask(with: request) { (data, response, error) in
            do {
                if let error = error { throw error }
                
                guard let data = data else { throw VersionError.invalidResponse }
                            
                let json = try JSONSerialization.jsonObject(with: data, options: [.allowFragments]) as? [String: Any]
                            
                guard let result = (json?["results"] as? [Any])?.first as? [String: Any], let appStoreVersion = result["version"] as? String else {
                    throw VersionError.invalidResponse
                }
                
                completion(appStoreVersion > appVersion, nil)
            } catch {
                completion(nil, error)
            }
        }
        
        task.resume()
        return task
    }
}

enum VersionError: Error {
    case invalidResponse, invalidBundleInfo
}
