//
//  BaseTabbarVC.swift
//  ViFi
//
//  Created by Emre BÜYÜKER on 15.05.2019.
//  Copyright © 2019 Emre BÜYÜKER. All rights reserved.
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
		
		VersionCheck.shared.checkAppStore() { isNew, version in
			print("IS NEW VERSION AVAILABLE: \(String(describing: isNew)), APP STORE VERSION: \(String(describing: version))")
			if (!(isNew ?? false)) {
				let alert = UIAlertController(title: "Error", message: "Uygulama en güncel sürüme sahip değil lütfen uygulamayı güncelleyiniz.", preferredStyle: .alert)
				self.present(alert, animated: true)
			}
		}
    }
}
